# Orange Pi Capture Device

Service that listens to Arduino sensor events (ultrasonic + RFID), captures an image on ultrasonic changes, sends it to a Roboflow model, and stores/logs the result, then (optionally) awards points via Supabase. Now supports multiple devices, offline award queue, per‑RFID rate limiting, and class-based point mapping.

## Key Features
- Serial listener with auto‑reconnect (Arduino over USB)
- Debounced ultrasonic triggers (state change + interval)
- Cooldown to limit capture spam
- USB camera capture (OpenCV)
- Roboflow inference via raw HTTP or `inference-sdk` (serverless endpoint)
- Multi-device identity (`DEVICE_ID`) + per-device credential validation (v2 RPC)
- Optional automatic points award (RFID → profile) via Supabase RPC
- Per-RFID rate limiting (env `AWARD_MIN_INTERVAL_SECONDS`)
- Offline award queue with retry flushing
- Optional class → points overrides (`AWARD_CLASS_POINTS`)
- Rotating logs & JSON result storage
- Systemd unit for auto-start on boot

## Directory Structure
```
device/
  orangepi_capture.py
  requirements.txt
  .env.example
  orangepi-capture.service
  README.md
  captures/ (runtime images + json)
  award_queue.jsonl (created if offline queue stores awards)
```

## Installation (Orange Pi)
```bash
sudo apt update && sudo apt install -y python3-venv python3-pip python3-opencv ffmpeg libatlas-base-dev
sudo mkdir -p /opt/cereal-device
sudo cp -r device/* /opt/cereal-device/
cd /opt/cereal-device
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
nano .env  # populate secrets & model id
```

Add current user to groups for serial/video:
```bash
sudo usermod -aG video,plugdev,dialout $(whoami)
```
Log out / in if group changes.

## Roboflow Configuration
Environment variables:
```
ROBOFLOW_API_KEY=...
ROBOFLOW_MODEL_ID=cereal-hzsdj/2
ROBOFLOW_USE_SDK=true   # (or false)
```
If `ROBOFLOW_USE_SDK=true` the script uses `InferenceHTTPClient` at `https://serverless.roboflow.com`, else raw multipart POST to `ROBOFLOW_API_BASE`.

## Multi-Device Provisioning
For each physical unit pick a unique `DEVICE_ID` (e.g. `DEVICE_A`, `DEVICE_B`, `DEVICE_C`) and generate a raw secret.

SQL (Supabase) provisioning example (replace placeholders):
```sql
insert into public.device_credentials(device_id, secret_hash)
values ('DEVICE_A', encode(digest('RAW_SECRET_A'||':'||'DEVICE_A','sha256'),'hex'))
on conflict (device_id) do update set secret_hash = excluded.secret_hash, active = true;
```
Repeat for each device. The device `.env` holds:
```
DEVICE_ID=DEVICE_A
DEVICE_DEVICE_SECRET=RAW_SECRET_A
```
If a device is compromised, set `active=false` or update hash with new secret.

## RFID → Profile Award Flow
1. Arduino emits `RFID UID=<hex>` lines; the service remembers the last UID.
2. When a capture produces predictions, if a last UID exists, it attempts award via `device_award_points_v2`.
3. On failure it falls back to legacy `device_award_points` (until you remove it).
4. If both fail, payload is appended to `award_queue.jsonl` and retried every `AWARD_QUEUE_FLUSH_SECONDS`.

## Offline Award Queue
- Stored as JSON lines at path `AWARD_QUEUE_PATH` (default `./award_queue.jsonl`).
- Background thread flushes every `AWARD_QUEUE_FLUSH_SECONDS`.
- Up to `AWARD_MAX_BATCH` entries per flush.
- Survives restarts (file is re-used).

## Per-RFID Rate Limiting
`AWARD_MIN_INTERVAL_SECONDS` enforces a minimum time between successful awards for the same RFID UID (default 30s). If called sooner, the attempt is silently skipped (no queue entry). This prevents rapid duplicate scan exploits.

## Class-Based Points (Optional)
Set `AWARD_CLASS_POINTS`, e.g.:
```
AWARD_CLASS_POINTS=plastic:5,metal:8,glass:10
```
If the top class matches a key, that point value overrides `AWARD_DEFAULT_POINTS`.

## Environment Variables Summary
```
ROBOFLOW_API_KEY          # Roboflow auth
ROBOFLOW_MODEL_ID         # e.g. cereal-hzsdj/2
ROBOFLOW_USE_SDK          # true/false
SERIAL_PORT               # /dev/ttyUSB0 or /dev/ttyACM0
SERIAL_BAUD               # 115200
CAPTURE_COOLDOWN_SECONDS  # min seconds between captures
ULTRA_EVENT_MIN_INTERVAL  # min seconds between periodic ultra events
IMAGE_SAVE_DIR            # folder for images
LOG_LEVEL                 # INFO/DEBUG
SUPABASE_URL              # Project REST base
SUPABASE_SERVICE_KEY      # Service role key (device only)
DEVICE_ID                 # Unique per device
DEVICE_DEVICE_SECRET      # Raw secret corresponding to hash in DB
AWARD_POINTS_ENABLED      # toggle awarding
AWARD_DEFAULT_POINTS      # base points
AWARD_MIN_INTERVAL_SECONDS# per-RFID rate limit
AWARD_QUEUE_PATH          # offline queue file
AWARD_QUEUE_FLUSH_SECONDS # flush interval
AWARD_MAX_BATCH           # flush batch size
AWARD_CLASS_POINTS        # optional class:points mapping
```

## Systemd Setup
```bash
sudo cp orangepi-capture.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable orangepi-capture.service
sudo systemctl start orangepi-capture.service
journalctl -u orangepi-capture.service -f
```

## Serial Protocol (Arduino → Pi)
```
ULTRA EVENT state=PRESENT dist_cm=23
ULTRA EVENT state=ABSENT dist_cm=402
RFID UID=AB12CD34
PING
```

## Award Logic (Code Excerpt)
```python
if rfid_uid and prediction_summary != "no_predictions":
    award_points_via_rfid(rfid_uid, AWARD_DEFAULT_POINTS, reason="classification_event", top_class=top_class)
```
Top class (if available) may override points via `AWARD_CLASS_POINTS` mapping.

## Rotating / Revoking a Device
1. Generate new secret.
2. Update hash row in `device_credentials`.
3. Update device `.env`.
4. Restart service.

## Troubleshooting
| Issue | Check |
|-------|-------|
| No serial data | Correct `/dev/ttyACM0` path & group membership |
| Camera fails | Another process using video device? Permissions? |
| No awards | Function permissions, secret mismatch, see logs |
| Queue not flushing | Verify `AWARD_QUEUE_FLUSH_SECONDS` and service logs |
| Rapid duplicate awards | Decrease `AWARD_MIN_INTERVAL_SECONDS` or confirm RFID UID stability |

## Operational Playbook
- Logs: `tail -f captures/orangepi_capture.log`
- Queue depth: `wc -l award_queue.jsonl`
- Manual flush: restart service or run `touch award_queue.jsonl` (thread flush occurs per interval).
- Inspect queued entries: `head award_queue.jsonl` (each line is JSON with body fields).

## Security Notes
- Never commit real `SUPABASE_SERVICE_KEY` or `DEVICE_DEVICE_SECRET`.
- Restrict EXECUTE on award functions to service role.
- Use per-device secrets so one compromise doesn’t expose all units.
- Consider moving to JWT-signed device tokens later for rotation without SQL edits.

## Next Enhancements (Ideas)
- HTTP health endpoint with queue length & last capture info.
- gRPC or MQTT event stream for real-time monitoring.
- Local model fallback if network down.
- Image pruning job (remove old captures after N days).

MIT License or similar (add if needed).
