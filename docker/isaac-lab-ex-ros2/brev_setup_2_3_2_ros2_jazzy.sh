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

echo "Installing the NVIDIA 580 driver..."
sudo apt-get update
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
  curl \
  "linux-headers-$(uname -r)" \
  nvidia-driver-580

echo "Downloading the Compose file..."
sudo install -d -m 0755 "$APP_DIR"
sudo curl -fsSL "$COMPOSE_URL" -o "$APP_DIR/compose.yaml"

# Brev runs its setup script only during initial provisioning. This service
# starts Compose after the driver-install reboot and on later VM boots.
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
Restart=on-failure
RestartSec=15s
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now docker.service
sudo systemctl enable "$SERVICE_NAME"

# The initial start may fail until reboot loads the new kernel module. The
# enabled service retries the same command after the reboot.
echo "Attempting the initial Compose startup..."
sudo docker compose -f "$APP_DIR/compose.yaml" up -d --remove-orphans || \
  echo "Compose will retry automatically after reboot."

# Schedule rather than immediately reboot so Brev can finish recording setup.
sudo shutdown -r +1 "Rebooting to load the NVIDIA 580 driver"
echo "Setup complete. The VM will reboot in approximately one minute."
