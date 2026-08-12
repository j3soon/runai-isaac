#!/bin/bash
set -euo pipefail

# References:
# - Isaac Sim 6.0.1 tested Linux driver (595.58.03):
#   https://docs.isaacsim.omniverse.nvidia.com/6.0.1/installation/requirements.html
# - Ubuntu packaged NVIDIA driver installation:
#   https://documentation.ubuntu.com/server/how-to/graphics/install-nvidia-drivers/
# - Brev VM Mode and setup-script lifecycle:
#   https://docs.nvidia.com/brev/concepts/launchables
# - Docker Compose restart policy:
#   https://docs.docker.com/reference/compose-file/services/#restart

# This variant pins the 595 driver branch, matching the 595.58.03 that Isaac
# Sim 6.0.1 was tested on. (The 6.0.0 page still lists 580.95.05; use the 6.0.1
# reference above for this image.)
#
# Brev's VM Mode base image already ships a 595.x kernel module, so in the
# normal case this script installs no driver and never reboots -- the deploy is
# just the image pull. Measured on g6e.xlarge: ~24 minutes create-to-ready,
# against ~30 for the 2.3.2 variant. The saving is smaller than the skipped
# ~12-minute driver install suggests, because the pull dominates and this
# image is larger (~38.7GB vs ~33.9GB). The real win is that nvidia-smi stays
# healthy throughout instead of failing for ~28 minutes.
#
# It falls back to installing the branch (and rebooting to load it) only if the
# base image ever ships something else.

APP_DIR="/opt/isaac-lab-ex-ros2"
COMPOSE_URL="https://raw.githubusercontent.com/j3soon/runai-isaac/main/docker/isaac-lab-ex-ros2/compose_3_0_0_beta2_patch1_ros2_jazzy.yaml"
SERVICE_NAME="isaac-lab-ex-ros2.service"
DRIVER_BRANCH="595"
# Setup can run for a while and the VM is not usable until it finishes. Publish
# the current phase so an operator can tell "still working" from "broken" with
# one command, and keep a transcript across any reboot.
STATE_FILE="/var/lib/isaac-lab-ex-ros2-setup.state"
LOG_FILE="/var/log/isaac-lab-ex-ros2-setup.log"

sudo install -m 0644 /dev/null "$LOG_FILE"
exec > >(sudo tee -a "$LOG_FILE") 2>&1

set_state() {
  echo "$1" | sudo tee "$STATE_FILE" >/dev/null
  echo "[setup] $(date -u +%H:%M:%S) state=$1"
}

set_state "preparing"
sudo apt-get update
command -v curl >/dev/null || \
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y curl
sudo systemctl enable --now docker.service

echo "Downloading the Compose file..."
sudo install -d -m 0755 "$APP_DIR"
sudo curl -fsSL "$COMPOSE_URL" -o "$APP_DIR/compose.yaml"

# Only touch the driver if the loaded kernel module is not already on the
# required branch. Installing a different branch over a loaded one leaves
# userspace and kernel module mismatched until a reboot, which is exactly the
# long, broken-looking window the 2.3.2 variant has to live with.
LOADED_DRIVER="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' /proc/driver/nvidia/version 2>/dev/null | head -1 || true)"
echo "[setup] loaded driver: ${LOADED_DRIVER:-none}"
NEEDS_REBOOT=0
if [[ "$LOADED_DRIVER" == "$DRIVER_BRANCH".* ]]; then
  set_state "driver-ok"
  echo "[setup] driver branch $DRIVER_BRANCH already loaded; no install, no reboot"
else
  set_state "installing-driver"
  echo "[setup] loaded driver is not $DRIVER_BRANCH.x; installing that branch"
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    "linux-headers-$(uname -r)" \
    "nvidia-driver-$DRIVER_BRANCH"
  NEEDS_REBOOT=1
fi

set_state "pulling-image"
sudo docker compose -f "$APP_DIR/compose.yaml" pull --quiet || \
  echo "[setup] image pull failed; the service will pull on next start"

# Brev runs its setup script only during initial provisioning. This service
# starts Compose on later VM boots as well.
sudo tee "/etc/systemd/system/$SERVICE_NAME" >/dev/null <<EOF
[Unit]
Description=Isaac Lab 3.0.0-beta2.patch1 Extended with ROS 2 Jazzy
Wants=docker.service network-online.target
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$APP_DIR
ExecStartPre=/usr/bin/nvidia-smi
ExecStart=/usr/bin/docker compose -f $APP_DIR/compose.yaml up -d --remove-orphans
ExecStartPost=/bin/sh -c 'echo ready > $STATE_FILE'
Restart=on-failure
RestartSec=15s
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"

if [ "$NEEDS_REBOOT" = "1" ]; then
  # Schedule rather than immediately reboot so Brev can finish recording setup.
  set_state "rebooting"
  sudo shutdown -r +1 "Rebooting to load the NVIDIA $DRIVER_BRANCH driver"
  echo "Setup complete. The VM will reboot in approximately one minute."
else
  # The loaded driver already matches, so start the application now and skip
  # the reboot entirely.
  set_state "starting"
  sudo systemctl start "$SERVICE_NAME"
  echo "Setup complete. The application is starting; no reboot required."
fi
