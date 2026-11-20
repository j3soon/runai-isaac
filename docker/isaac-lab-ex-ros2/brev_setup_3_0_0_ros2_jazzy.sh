#!/bin/bash
set -euo pipefail

APP_DIR="/opt/isaac-lab-ex-ros2"
COMPOSE_URL="https://raw.githubusercontent.com/j3soon/runai-isaac/main/docker/isaac-lab-ex-ros2/compose_3_0_0_ros2_jazzy.yaml"
SERVICE_NAME="isaac-lab-ex-ros2.service"
STATE_FILE="/var/lib/isaac-lab-ex-ros2-setup.state"
LOG_FILE="/var/log/isaac-lab-ex-ros2-setup.log"

sudo touch "$LOG_FILE"
exec > >(sudo tee -a "$LOG_FILE") 2>&1

set_state() {
  echo "$1" | sudo tee "$STATE_FILE" >/dev/null
  echo "[setup] $(date -u +%H:%M:%S) state=$1"
}

trap 'set_state failed' ERR
set_state "preparing"
# Use the GPU stack supplied by Brev VM Mode. Isaac Sim 6.2 was tested
# on Linux with driver 595.58.03. A functional NVIDIA Vulkan device is
# checked inside the container before the service reports ready.
# https://docs.isaacsim.omniverse.nvidia.com/6.2.0/installation/requirements.html
if ! nvidia-smi --query-gpu=name,driver_version --format=csv,noheader; then
  echo "[setup] Brev's host NVIDIA driver is unavailable" >&2
  set_state "failed"
  exit 1
fi

sudo systemctl enable --now docker.service
sudo install -d -m 0755 "$APP_DIR"
if [ ! -d /workspace ]; then
  sudo install -d -o 1000 -g 1000 -m 0755 /workspace
fi
sudo curl -fsSL "$COMPOSE_URL" -o "$APP_DIR/compose.yaml"

set_state "pulling-image"
sudo docker compose -f "$APP_DIR/compose.yaml" pull --quiet

# Brev runs setup on the initial boot. systemd restores the app after VM restarts.
sudo tee "/etc/systemd/system/$SERVICE_NAME" >/dev/null <<EOF
[Unit]
Description=Isaac Lab 3.0.0, Sim 6.2.0, ROS 2 Jazzy
Wants=docker.service network-online.target
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$APP_DIR
Environment=WORKSPACE_DIR=/workspace
ExecStartPre=/bin/sh -c 'echo starting > $STATE_FILE'
ExecStartPre=/usr/bin/nvidia-smi
ExecStart=/usr/bin/docker compose -f $APP_DIR/compose.yaml up -d --remove-orphans
ExecStartPost=/usr/bin/docker compose -f $APP_DIR/compose.yaml exec -T --user isaaclab isaac-sim-ex /bin/bash -o pipefail -c 'vulkaninfo --summary | tee /dev/stderr | grep -E "driverID.*NVIDIA_PROPRIETARY"'
ExecStartPost=/bin/sh -c 'echo ready > $STATE_FILE'
Restart=on-failure
RestartSec=15s
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"
set_state "starting"
sudo systemctl restart "$SERVICE_NAME"
