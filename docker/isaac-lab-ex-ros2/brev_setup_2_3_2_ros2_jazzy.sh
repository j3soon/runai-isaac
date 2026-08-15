#!/bin/bash
set -euo pipefail

# References:
# - Isaac Sim 5.1 tested Linux driver (580.65.06):
#   https://docs.isaacsim.omniverse.nvidia.com/5.1.0/installation/requirements.html
# - Ubuntu packaged NVIDIA driver installation:
#   https://documentation.ubuntu.com/server/how-to/graphics/install-nvidia-drivers/
# - Brev VM Mode and setup-script lifecycle:
#   https://docs.nvidia.com/brev/concepts/launchables
# - Docker Compose restart policy:
#   https://docs.docker.com/reference/compose-file/services/#restart

APP_DIR="/opt/isaac-lab-ex-ros2"
COMPOSE_URL="https://raw.githubusercontent.com/j3soon/runai-isaac/main/docker/isaac-lab-ex-ros2/compose_2_3_2_ros2_jazzy.yaml"
SERVICE_NAME="isaac-lab-ex-ros2.service"
DRIVER_BRANCH="580"
# Setup can run for a while and the VM is not usable until it finishes. Publish
# the current phase so an operator can tell "still working" from "broken" with
# one command, and keep a transcript of the setup.
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

set_state "checking-driver"
DRIVER_VERSION="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits 2>/dev/null | head -1 || true)"
NEEDS_REBOOT=0
if [[ "$DRIVER_VERSION" == "$DRIVER_BRANCH".* ]]; then
  echo "[setup] detected NVIDIA driver $DRIVER_VERSION; leaving NVIDIA packages unchanged"
else
  set_state "installing-driver"
  echo "[setup] detected NVIDIA driver ${DRIVER_VERSION:-none}; installing branch $DRIVER_BRANCH"
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    "linux-headers-$(uname -r)" \
    "nvidia-driver-$DRIVER_BRANCH"
  NEEDS_REBOOT=1
fi

# Pull before a possible reboot, but do NOT run `docker compose up -d` here:
# when the driver changed, the container cannot start until the reboot loads
# the 580 kernel module, so an attempt now only fails and the pull is the only
# useful part of it.
#
# Measured on a g6e.xlarge (4 vCPU): running this pull concurrently with the
# driver install does NOT help. Overlapping them stretched the install from ~12
# to ~25 minutes and the pull from ~16 to ~30, for ~33 minutes total against ~30
# sequential -- the DKMS build and the image decompression contend for the same
# few cores. Keep them sequential.
set_state "pulling-image"
sudo docker compose -f "$APP_DIR/compose.yaml" pull --quiet || \
  echo "[setup] image pull failed; the service will pull on next start"

# Brev runs its setup script only during initial provisioning. This service
# starts Compose immediately when 580.x is already loaded, after a driver-change
# reboot otherwise, and on later VM boots.
sudo tee "/etc/systemd/system/$SERVICE_NAME" >/dev/null <<EOF
[Unit]
Description=Isaac Lab 2.3.2 Extended with ROS 2 Jazzy
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
  # The enabled unit starts Compose on the next boot, by which point the driver
  # is loaded and the image is already local, so the container appears within
  # seconds of the reboot rather than after another long pull.

  # Schedule rather than immediately reboot so Brev can finish recording setup.
  set_state "rebooting"
  sudo shutdown -r +1 "Rebooting to load the NVIDIA $DRIVER_BRANCH driver"
  echo "Setup complete. The VM will reboot in approximately one minute."
else
  set_state "starting"
  sudo systemctl start "$SERVICE_NAME"
  set_state "ready"
  echo "Setup complete. The application is running; no reboot required."
fi
