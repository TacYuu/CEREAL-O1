#!/usr/bin/env bash
# Armbian provisioning script for Cereal capture device
# Idempotent: safe to re-run. Installs dependencies, creates venv, deploys service.
# Usage:
#   sudo bash setup_armbian.sh --device-id DEVICE_A --repo-path /home/armbian/CEREAL-O1/frontend/device \
#       --install-dir /opt/cereal-device --python 3.11
# Then edit /opt/cereal-device/.env (created from example) and put secrets.

set -euo pipefail

DEVICE_ID="DEVICE_A"
REPO_PATH="$(pwd)"  # path containing orangepi_capture.py
INSTALL_DIR="/opt/cereal-device"
PYTHON_VERSION=""
SYSTEM_USER="$(logname 2>/dev/null || echo ${SUDO_USER:-orangepi})"
SKIP_APT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device-id) DEVICE_ID="$2"; shift 2;;
    --repo-path) REPO_PATH="$2"; shift 2;;
    --install-dir) INSTALL_DIR="$2"; shift 2;;
    --python) PYTHON_VERSION="$2"; shift 2;;
    --system-user) SYSTEM_USER="$2"; shift 2;;
    --skip-apt) SKIP_APT=1; shift 1;;
    -h|--help)
      grep '^#' "$0" | head -n 40; exit 0;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

echo "==> Provisioning for device id: $DEVICE_ID"
echo "==> Using repo path: $REPO_PATH"
echo "==> Install dir: $INSTALL_DIR"
echo "==> System user: $SYSTEM_USER"

if [[ $EUID -ne 0 ]]; then
  echo "Please run with sudo" >&2
  exit 1
fi

if [[ $SKIP_APT -eq 0 ]]; then
  echo "==> Updating APT & installing packages"
  apt-get update -y
  apt-get install -y python3 python3-venv python3-pip ffmpeg libatlas-base-dev \
     libjpeg-dev zlib1g-dev libgl1 wget curl git build-essential
fi

mkdir -p "$INSTALL_DIR"
cp -r "$REPO_PATH"/* "$INSTALL_DIR"/
cd "$INSTALL_DIR"

# Python selection
PY=python3
if [[ -n "$PYTHON_VERSION" ]]; then
  if command -v "python$PYTHON_VERSION" >/dev/null 2>&1; then
    PY="python$PYTHON_VERSION"
  else
    echo "Requested python version $PYTHON_VERSION not found; using default python3" >&2
  fi
fi

echo "==> Creating / updating venv"
$PY -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

echo "==> Preparing .env"
if [[ ! -f .env ]]; then
  cp .env.example .env
  sed -i "s/^DEVICE_ID=.*/DEVICE_ID=$DEVICE_ID/" .env || true
  echo "Populated .env from example (remember to add real secrets)."
fi

# Adjust permissions
chown -R "$SYSTEM_USER":"$SYSTEM_USER" "$INSTALL_DIR"
chmod 750 "$INSTALL_DIR"

# Create / overwrite systemd unit (always ensure latest config)
SERVICE_PATH="/etc/systemd/system/orangepi-capture.service"
echo "==> Writing systemd service to $SERVICE_PATH"
cat > "$SERVICE_PATH" <<UNIT
[Unit]
Description=Orange Pi Capture & Roboflow Service
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=-$INSTALL_DIR/.env
ExecStartPre=/usr/bin/test -f $INSTALL_DIR/orangepi_capture.py
ExecStart=$INSTALL_DIR/venv/bin/python -u $INSTALL_DIR/orangepi_capture.py
Restart=always
RestartSec=3
User=$SYSTEM_USER
Group=$SYSTEM_USER
StandardOutput=journal
StandardError=journal
SyslogIdentifier=orangepi-capture
TimeoutStopSec=20
OOMScoreAdjust=-500
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
ReadWriteDirectories=$INSTALL_DIR
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
LockPersonality=true
RestrictRealtime=true
RestrictSUIDSGID=true
CapabilityBoundingSet=CAP_CHOWN CAP_DAC_OVERRIDE CAP_FOWNER CAP_FSETID CAP_MKNOD CAP_NET_BIND_SERVICE CAP_SETFCAP CAP_SETGID CAP_SETUID CAP_SYS_CHROOT

[Install]
WantedBy=multi-user.target
UNIT
echo "==> Systemd unit installed/updated"

# Enable serial/video access
groups "$SYSTEM_USER" | grep -q video || usermod -aG video "$SYSTEM_USER" || true
groups "$SYSTEM_USER" | grep -q dialout || usermod -aG dialout "$SYSTEM_USER" || true
groups "$SYSTEM_USER" | grep -q plugdev || usermod -aG plugdev "$SYSTEM_USER" || true

echo "==> Reloading systemd daemon & enabling service"
systemctl daemon-reload
systemctl enable orangepi-capture.service
systemctl restart orangepi-capture.service || true
systemctl --no-pager status orangepi-capture.service || true

echo "==> Setup complete"
echo "Edit $INSTALL_DIR/.env and restart service: systemctl restart orangepi-capture.service"

# Optional logrotate suggestion (manual step):
# cat >/etc/logrotate.d/cereal-device <<'LOG'
# /opt/cereal-device/captures/orangepi_capture.log {
#   weekly
#   rotate 6
#   compress
#   missingok
#   notifempty
#   copytruncate
# }
# LOG
