#!/bin/bash
set -euo pipefail

# Brev VM-mode setup script for j3soon/runai-hcis-lab-aicapstone.
#
# Paste this into a Brev Launchable's VM setup script, or attach it with
# `brev create --startup-script`. Track progress with
# `cat /var/lib/aicapstone-setup.state` and wait for `ready`.
#
# Modeled on docker/isaac-lab-ex-ros2/brev_setup_2_3_2_ros2_jazzy.sh. Differences: this image is a
# batch workload rather than a long-running service, so there is no Compose file and no service to
# start -- the systemd unit exists only to publish a `ready` phase once the driver is usable after
# a reboot. Launch the workload yourself over SSH; see this image's README.
#
# References:
# - Isaac Sim 5.1 tested Linux driver (580.65.06):
#   https://docs.isaacsim.omniverse.nvidia.com/5.1.0/installation/requirements.html
# - Isaac Sim 5.1.0 fails on the 595 branch: https://github.com/isaac-sim/IsaacSim/issues/537
# - Brev VM Mode and setup-script lifecycle:
#   https://docs.nvidia.com/brev/concepts/launchables

IMAGE="j3soon/runai-hcis-lab-aicapstone:latest"
SERVICE_NAME="aicapstone-ready.service"
DRIVER_BRANCH="580"
STATE_FILE="/var/lib/aicapstone-setup.state"
LOG_FILE="/var/log/aicapstone-setup.log"

sudo install -m 0644 /dev/null "$LOG_FILE"
exec > >(sudo tee -a "$LOG_FILE") 2>&1

set_state() {
  echo "$1" | sudo tee "$STATE_FILE" >/dev/null
  echo "[setup] $(date -u +%H:%M:%S) state=$1"
}

set_state "preparing"

# Brev's own provisioning runs apt-get concurrently with this script. With `set -e`, losing the
# race to the dpkg/apt lock kills the setup outright and the phase file stays at "preparing",
# which looks like a stalled instance rather than a failed one. Wait for the lock before touching
# apt, and retry the update rather than dying on a transient failure.
wait_for_apt() {
  for _ in $(seq 1 120); do
    if ! sudo fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock \
         /var/lib/dpkg/lock >/dev/null 2>&1; then
      return 0
    fi
    echo "[setup] waiting for another apt/dpkg process to release its lock"
    sleep 15
  done
  echo "[setup] apt lock still held after 30 min; continuing anyway"
}

apt_get() {
  wait_for_apt
  for attempt in 1 2 3; do
    if sudo env DEBIAN_FRONTEND=noninteractive apt-get "$@"; then return 0; fi
    echo "[setup] apt-get $1 failed (attempt $attempt); retrying"
    sleep 20; wait_for_apt
  done
  return 1
}

apt_get update
command -v curl >/dev/null || \
  apt_get install -y curl
sudo systemctl enable --now docker.service

# Brev's AWS base image ships the 595 branch, but this image pins Isaac Sim 5.1.0,
# which NVIDIA tests against 580. Detect rather than assume, so the script still
# does the right thing if Brev changes its base image.
set_state "checking-driver"
DRIVER_VERSION="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits 2>/dev/null | head -1 || true)"
NEEDS_REBOOT=0
if [[ "$DRIVER_VERSION" == "$DRIVER_BRANCH".* ]]; then
  echo "[setup] detected NVIDIA driver $DRIVER_VERSION; leaving NVIDIA packages unchanged"
else
  set_state "installing-driver"
  echo "[setup] detected NVIDIA driver ${DRIVER_VERSION:-none}; installing branch $DRIVER_BRANCH"
  apt_get install -y \
    "linux-headers-$(uname -r)" \
    "nvidia-driver-$DRIVER_BRANCH"
  NEEDS_REBOOT=1
fi

# Sequential with the driver install, deliberately. Measured on a 4 vCPU g6e.xlarge,
# overlapping the two makes both slower -- the DKMS build and the image decompression
# contend for the same few cores.
set_state "pulling-image"
sudo docker pull "$IMAGE" || echo "[setup] image pull failed; pull it by hand before running"

# Publishes `ready` once nvidia-smi passes, which after a driver-change reboot is
# the first moment the GPU is actually usable. Nothing to start: the image runs
# batch commands, so the operator launches the workload over SSH.
sudo tee "/etc/systemd/system/$SERVICE_NAME" >/dev/null <<EOF
[Unit]
Description=Mark HCIS-Lab AICapstone VM ready
Wants=docker.service network-online.target
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/usr/bin/nvidia-smi
ExecStart=/bin/sh -c 'echo ready > $STATE_FILE'
Restart=on-failure
RestartSec=15s
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"

if [ "$NEEDS_REBOOT" = "1" ]; then
  # Schedule rather than reboot immediately, so Brev can finish recording setup.
  set_state "rebooting"
  sudo shutdown -r +1 "Rebooting to load the NVIDIA $DRIVER_BRANCH driver"
  echo "Setup complete. The VM will reboot in approximately one minute."
else
  sudo systemctl start "$SERVICE_NAME"
  set_state "ready"
  echo "Setup complete. No reboot required."
fi
