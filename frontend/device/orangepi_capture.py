#!/usr/bin/env python3
"""Orange Pi capture & classify service.
Listens to Arduino over serial for ultrasonic change events.
On event: capture image from USB camera, send to Roboflow, log result.
"""
import os
import time
import json
import threading
import queue
import logging
import logging.handlers
from datetime import datetime

import cv2  # type: ignore
import requests
import serial  # type: ignore
from dotenv import load_dotenv

# Optional Roboflow inference SDK
ROBOFLOW_USE_SDK = os.getenv("ROBOFLOW_USE_SDK", "false").lower() in {"1","true","yes"}
if ROBOFLOW_USE_SDK:
    try:
        from inference_sdk import InferenceHTTPClient  # type: ignore
    except Exception as e:  # pragma: no cover
        print(f"[WARN] ROBOFLOW_USE_SDK set but inference_sdk import failed: {e}")
        ROBOFLOW_USE_SDK = False

load_dotenv()  # Load .env if present

# Environment / Config
ROBOFLOW_API_KEY = os.getenv("ROBOFLOW_API_KEY")
ROBOFLOW_MODEL_ID = os.getenv("ROBOFLOW_MODEL_ID", "")
ROBOFLOW_API_BASE = os.getenv("ROBOFLOW_API_BASE", "https://detect.roboflow.com")
SERIAL_PORT = os.getenv("SERIAL_PORT", "/dev/ttyUSB0")
SERIAL_BAUD = int(os.getenv("SERIAL_BAUD", "115200"))
CAPTURE_COOLDOWN_SECONDS = float(os.getenv("CAPTURE_COOLDOWN_SECONDS", "5"))
ULTRA_EVENT_MIN_INTERVAL = float(os.getenv("ULTRA_EVENT_MIN_INTERVAL", "2"))
IMAGE_SAVE_DIR = os.getenv("IMAGE_SAVE_DIR", "./captures")
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO").upper()
CAMERA_INDEX = int(os.getenv("CAMERA_INDEX", "0"))
REQUEST_TIMEOUT = float(os.getenv("REQUEST_TIMEOUT", "10"))
MAX_RETRIES = 3

SUPABASE_URL = os.getenv("SUPABASE_URL")
SUPABASE_SERVICE_KEY = os.getenv("SUPABASE_SERVICE_KEY")
DEVICE_DEVICE_SECRET = os.getenv("DEVICE_DEVICE_SECRET")  # device award secret
DEVICE_ID = os.getenv("DEVICE_ID", "UNSET_DEVICE")

os.makedirs(IMAGE_SAVE_DIR, exist_ok=True)

# Logging setup
logger = logging.getLogger("orangepi")
logger.setLevel(LOG_LEVEL)
log_path = os.path.join(IMAGE_SAVE_DIR, "orangepi_capture.log")
handler = logging.handlers.RotatingFileHandler(log_path, maxBytes=2_000_000, backupCount=3)
fmt = logging.Formatter("%(asctime)s %(levelname)s %(message)s")
handler.setFormatter(fmt)
logger.addHandler(handler)
logger.addHandler(logging.StreamHandler())

# Thread-safe queue for events
capture_queue: "queue.Queue[dict]" = queue.Queue()

last_capture_ts = 0.0
last_ultra_state = None  # PRESENT / ABSENT
last_ultra_event_ts = 0.0
last_rfid_uid = None  # store last scanned UID for awarding points

# Initialize Roboflow client if SDK is enabled
RF_CLIENT = None
if ROBOFLOW_USE_SDK and ROBOFLOW_API_KEY and ROBOFLOW_MODEL_ID:
    try:
        RF_CLIENT = InferenceHTTPClient(api_url="https://serverless.roboflow.com", api_key=ROBOFLOW_API_KEY)
        logger.info("Roboflow inference SDK initialized (serverless)")
    except Exception as e:
        logger.warning(f"Failed to init inference SDK; falling back to raw HTTP: {e}")
        RF_CLIENT = None
        ROBOFLOW_USE_SDK = False


class SerialListener(threading.Thread):
    def __init__(self, port: str, baud: int):
        super().__init__(daemon=True)
        self.port = port
        self.baud = baud
        self._stop = threading.Event()
        self.ser = None

    def run(self):
        global last_ultra_state, last_ultra_event_ts, last_rfid_uid
        while not self._stop.is_set():
            if self.ser is None:
                try:
                    logger.info(f"Opening serial {self.port} @ {self.baud}")
                    self.ser = serial.Serial(self.port, self.baud, timeout=1)
                except Exception as e:
                    logger.error(f"Serial open failed: {e}; retry in 5s")
                    time.sleep(5)
                    continue
            try:
                line = self.ser.readline().decode(errors="ignore").strip()
                if not line:
                    continue
                logger.debug(f"SERIAL: {line}")
                if line.startswith("ULTRA EVENT"):
                    parts = line.split()
                    state = None
                    dist = None
                    for p in parts:
                        if p.startswith("state="):
                            state = p.split("=",1)[1]
                        elif p.startswith("dist_cm="):
                            dist = p.split("=",1)[1]
                    now = time.time()
                    if state and state != last_ultra_state:
                        last_ultra_state = state
                        last_ultra_event_ts = now
                        enqueue_capture(reason=f"ultra_state_change:{state}", meta={"distance": dist, "state": state, "rfid_uid": last_rfid_uid})
                    else:
                        if now - last_ultra_event_ts >= ULTRA_EVENT_MIN_INTERVAL:
                            last_ultra_event_ts = now
                            enqueue_capture(reason=f"ultra_interval:{state}", meta={"distance": dist, "state": state, "rfid_uid": last_rfid_uid})
                elif line.startswith("RFID UID="):
                    uid = line.split("RFID UID=",1)[1]
                    last_rfid_uid = uid
                    logger.info(f"RFID read: {uid}")
                elif line == "PING":
                    logger.debug("Heartbeat received")
                else:
                    logger.debug(f"Unrecognized line: {line}")
            except serial.SerialException as e:
                logger.error(f"Serial error: {e}; closing and retrying")
                self._close_serial()
                time.sleep(2)
            except Exception as e:
                logger.exception(f"Unexpected error in serial loop: {e}")

    def _close_serial(self):
        if self.ser:
            try:
                self.ser.close()
            except Exception:
                pass
            self.ser = None

    def stop(self):
        self._stop.set()
        self._close_serial()


def enqueue_capture(reason: str, meta: dict):
    global last_capture_ts
    now = time.time()
    if now - last_capture_ts < CAPTURE_COOLDOWN_SECONDS:
        logger.info(f"Cooldown active, skipping capture (reason={reason})")
        return
    evt = {"reason": reason, "meta": meta, "ts": now}
    capture_queue.put(evt)
    last_capture_ts = now
    logger.info(f"Queued capture: {reason} meta={meta}")


def open_camera(index: int):
    cam = cv2.VideoCapture(index)
    if not cam.isOpened():
        raise RuntimeError(f"Cannot open camera index {index}")
    return cam


def capture_image(cam) -> str:
    ret, frame = cam.read()
    if not ret:
        raise RuntimeError("Failed to read frame from camera")
    ts = datetime.utcnow().strftime("%Y%m%dT%H%M%S%fZ")
    filename = f"capture_{ts}.jpg"
    path = os.path.join(IMAGE_SAVE_DIR, filename)
    cv2.imwrite(path, frame)
    return path


def call_roboflow_http(image_path: str) -> dict:
    if not ROBOFLOW_MODEL_ID:
        raise RuntimeError("ROBOFLOW_MODEL_ID not configured")
    url = f"{ROBOFLOW_API_BASE.rstrip('/')}/{ROBOFLOW_MODEL_ID}"
    params = {}
    if ROBOFLOW_API_KEY:
        params["api_key"] = ROBOFLOW_API_KEY
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            with open(image_path, "rb") as f:
                files = {"file": f}
                resp = requests.post(url, params=params, files=files, timeout=REQUEST_TIMEOUT)
            if resp.status_code == 200:
                return resp.json()
            else:
                logger.warning(f"Roboflow HTTP {resp.status_code}: {resp.text[:200]}")
        except Exception as e:
            logger.warning(f"Roboflow attempt {attempt} failed: {e}")
        time.sleep(2 ** attempt)
    raise RuntimeError("Roboflow request failed after retries")


def call_roboflow_sdk(image_path: str) -> dict:
    if RF_CLIENT is None:
        raise RuntimeError("RF_CLIENT not initialized")
    # inference_sdk handles retry internally; catch exceptions
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            res = RF_CLIENT.infer(image_path, model_id=ROBOFLOW_MODEL_ID)
            return res
        except Exception as e:
            logger.warning(f"SDK inference attempt {attempt} failed: {e}")
            time.sleep(2 ** attempt)
    raise RuntimeError("Roboflow SDK inference failed after retries")


def call_roboflow(image_path: str) -> dict:
    if ROBOFLOW_USE_SDK and RF_CLIENT:
        return call_roboflow_sdk(image_path)
    return call_roboflow_http(image_path)


AWARD_POINTS_ENABLED = os.getenv("AWARD_POINTS_ENABLED", "true").lower() in {"1","true","yes"}
AWARD_DEFAULT_POINTS = int(os.getenv("AWARD_DEFAULT_POINTS", "5"))
AWARD_MIN_INTERVAL_SECONDS = int(os.getenv("AWARD_MIN_INTERVAL_SECONDS", "30"))
AWARD_QUEUE_PATH = os.getenv("AWARD_QUEUE_PATH", "./award_queue.jsonl")
AWARD_QUEUE_FLUSH_SECONDS = int(os.getenv("AWARD_QUEUE_FLUSH_SECONDS", "60"))
AWARD_MAX_BATCH = int(os.getenv("AWARD_MAX_BATCH", "50"))
CLASS_POINTS_MAP = {}
cls_points_env = os.getenv("AWARD_CLASS_POINTS")
if cls_points_env:
    for pair in cls_points_env.split(','):
        if ':' in pair:
            k,v = pair.split(':',1)
            try:
                CLASS_POINTS_MAP[k.strip()] = int(v.strip())
            except ValueError:
                pass

_last_award_per_rfid = {}
_award_queue_lock = threading.Lock()

# Ensure queue file exists
if not os.path.exists(AWARD_QUEUE_PATH):
    try:
        open(AWARD_QUEUE_PATH, 'a').close()
    except Exception:
        logger.warning(f"Cannot create queue file {AWARD_QUEUE_PATH}")


def _eligible_for_award(rfid_uid: str) -> bool:
    now = time.time()
    last = _last_award_per_rfid.get(rfid_uid, 0)
    if now - last < AWARD_MIN_INTERVAL_SECONDS:
        logger.info(f"Rate limit: skipping award for {rfid_uid} (wait {AWARD_MIN_INTERVAL_SECONDS - (now - last):.1f}s)")
        return False
    return True


def _record_award_timestamp(rfid_uid: str):
    _last_award_per_rfid[rfid_uid] = time.time()


def _enqueue_award(payload: dict):
    try:
        with _award_queue_lock, open(AWARD_QUEUE_PATH, 'a', encoding='utf-8') as f:
            f.write(json.dumps(payload) + '\n')
        logger.info(f"Queued award offline: {payload}")
    except Exception as e:
        logger.error(f"Failed to persist award queue entry: {e}")


def _drain_award_queue_once():
    if not os.path.exists(AWARD_QUEUE_PATH):
        return
    try:
        with _award_queue_lock:
            with open(AWARD_QUEUE_PATH, 'r', encoding='utf-8') as f:
                lines = f.readlines()
            if not lines:
                return
            # Attempt processing
            remaining = []
            processed = 0
            for line in lines:
                if processed >= AWARD_MAX_BATCH:
                    remaining.append(line)
                    continue
                line = line.strip()
                if not line:
                    continue
                try:
                    payload = json.loads(line)
                except Exception:
                    continue
                ok = _attempt_award_rpc(payload)
                if ok:
                    processed += 1
                else:
                    remaining.append(line + '\n')
            # Rewrite file with remaining
            with open(AWARD_QUEUE_PATH, 'w', encoding='utf-8') as f:
                f.writelines(remaining)
            if processed:
                logger.info(f"Flushed {processed} queued award(s)")
    except Exception as e:
        logger.warning(f"Award queue flush error: {e}")


def _award_queue_worker():
    while True:
        time.sleep(AWARD_QUEUE_FLUSH_SECONDS)
        _drain_award_queue_once()


def _attempt_award_rpc(payload: dict) -> bool:
    endpoints = payload.get('_endpoints')
    if not endpoints:
        endpoints = [
            ("device_award_points_v2", True),
            ("device_award_points", False),
        ]
    for func, v2 in endpoints:
        try:
            url = f"{SUPABASE_URL}/rest/v1/rpc/{func}"
            headers = {
                "apikey": SUPABASE_SERVICE_KEY,
                "Authorization": f"Bearer {SUPABASE_SERVICE_KEY}",
                "Content-Type": "application/json",
            }
            resp = requests.post(url, headers=headers, json=payload['body'], timeout=REQUEST_TIMEOUT)
            if resp.status_code == 200:
                logger.info(f"Award success ({func}): {resp.json()}")
                return True
            else:
                logger.warning(f"Award attempt {func} HTTP {resp.status_code}: {resp.text[:160]}")
        except Exception as e:
            logger.warning(f"Award attempt {func} failed: {e}")
    return False



def get_profile_id_by_rfid(rfid_uid: str) -> str | None:
    """Look up profile id in Supabase by RFID UID."""
    if not SUPABASE_URL or not SUPABASE_SERVICE_KEY:
        logger.warning("Supabase config missing for profile lookup")
        return None
    url = f"{SUPABASE_URL}/rest/v1/profiles?rfid_uid=eq.{rfid_uid}"
    headers = {
        "apikey": SUPABASE_SERVICE_KEY,
        "Authorization": f"Bearer {SUPABASE_SERVICE_KEY}",
        "Content-Type": "application/json",
        "Prefer": "return=representation"
    }
    try:
        resp = requests.get(url, headers=headers, timeout=REQUEST_TIMEOUT)
        resp.raise_for_status()
        data = resp.json()
        if data and isinstance(data, list) and "id" in data[0]:
            return data[0]["id"]
        else:
            logger.info(f"No profile found for RFID UID {rfid_uid}")
            return None
    except Exception as e:
        logger.warning(f"Profile lookup failed for RFID UID {rfid_uid}: {e}")
        return None

def award_points_via_rfid(rfid_uid: str, points: int, reason: str = "auto_classification", top_class: str | None = None):
    if not AWARD_POINTS_ENABLED:
        logger.debug("Award disabled by config")
        return
    if not (SUPABASE_URL and SUPABASE_SERVICE_KEY):
        logger.debug("Supabase award skipped: missing config")
        return
    if not _eligible_for_award(rfid_uid):
        return
    # Adjust points by class if mapping provided
    if top_class and top_class in CLASS_POINTS_MAP:
        points = CLASS_POINTS_MAP[top_class]
    profile_id = get_profile_id_by_rfid(rfid_uid)
    if not profile_id:
        logger.info(f"Skipping award: no profile for RFID UID {rfid_uid}")
        return
    payload_body = {
        "in_id": profile_id,
        "in_points": points,
        "in_reason": reason
    }
    payload = {
        'body': payload_body,
        '_endpoints': [("device_award_points_v2", True), ("device_award_points", False)]
    }
    if _attempt_award_rpc(payload):
        _record_award_timestamp(rfid_uid)
        return
    # queue for later
    _enqueue_award(payload)

# Start award queue worker thread
if SUPABASE_URL and SUPABASE_SERVICE_KEY:
    t_award = threading.Thread(target=_award_queue_worker, daemon=True)
    t_award.start()


def process_captures():
    cam = None
    while True:
        evt = capture_queue.get()
        if evt is None:  # sentinel for shutdown
            break
        reason = evt["reason"]
        rfid_uid = evt.get("meta", {}).get("rfid_uid")
        try:
            if cam is None:
                cam = open_camera(CAMERA_INDEX)
            image_path = capture_image(cam)
            logger.info(f"Captured image {image_path} for reason={reason}")
            result = call_roboflow(image_path)
            json_path = image_path + ".json"
            with open(json_path, "w", encoding="utf-8") as jf:
                json.dump(result, jf, ensure_ascii=False, indent=2)
            prediction_summary = summarize_predictions(result)
            logger.info(f"Classification: {prediction_summary}")
            # Determine top class for points mapping
            top_class = None
            if isinstance(result, dict):
                if 'predictions' in result and isinstance(result['predictions'], list) and result['predictions']:
                    top = max(result['predictions'], key=lambda p: p.get('confidence',0))
                    top_class = top.get('class') or top.get('label')
            if rfid_uid and prediction_summary != "no_predictions":
                award_points_via_rfid(rfid_uid, AWARD_DEFAULT_POINTS, reason="classification_event", top_class=top_class)
        except Exception as e:
            logger.exception(f"Capture processing failed: {e}")
            if cam is not None:
                try:
                    cam.release()
                except Exception:
                    pass
                cam = None
        finally:
            capture_queue.task_done()


def summarize_predictions(result: dict) -> str:
    if not isinstance(result, dict):
        return "<invalid result>"
    if "predictions" in result and isinstance(result["predictions"], list) and result["predictions"]:
        preds = result["predictions"]
        top = max(preds, key=lambda p: p.get("confidence", 0))
        cls = top.get("class") or top.get("label") or "?"
        conf = top.get("confidence", 0)
        return f"top={cls} conf={conf:.2f} count={len(preds)}"
    if "predictions" in result and isinstance(result["predictions"], dict):
        items = list(result["predictions"].items())
        if items:
            top = max(items, key=lambda kv: kv[1])
            return f"top={top[0]} conf={top[1]:.2f}"
    return "no_predictions"


def main():
    logger.info("Starting Orange Pi capture service")
    worker = threading.Thread(target=process_captures, daemon=True)
    worker.start()

    serial_thread = SerialListener(SERIAL_PORT, SERIAL_BAUD)
    serial_thread.start()

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        logger.info("Shutting down (KeyboardInterrupt)")
    finally:
        serial_thread.stop()
        capture_queue.put(None)
        capture_queue.join()
        logger.info("Shutdown complete")


if __name__ == "__main__":
    main()
