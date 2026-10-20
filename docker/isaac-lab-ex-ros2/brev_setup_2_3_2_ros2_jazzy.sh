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
# AWS/GCP: Brev's local CDI refresh unit runs after Docker and restarts it.
# NVIDIA Container Toolkit 1.20.1 added a Before=docker.service drop-in, creating a cycle
# that made systemd skip refresh at boot. The stale CDI specification still
# mounted removed 595 libraries, so GPU containers failed even with host 580.
# Restrict the override to Brev's local After=docker.service unit on AWS/GCP.
CDI_REFRESH_AFTER=""
if [ -f /etc/systemd/system/nvidia-cdi-refresh.service ] &&
   grep -Eq '^After=.*docker\.service' /etc/systemd/system/nvidia-cdi-refresh.service; then
  # Compose must wait until Brev's refresh and its Docker restart finish.
  CDI_REFRESH_AFTER="nvidia-cdi-refresh.service"
  if [ -f /usr/lib/systemd/system/nvidia-cdi-refresh.service.d/10-container-engines.conf ]; then
    # A same-named empty local drop-in masks NVIDIA's 10-container-engines.conf.
    # An empty Before= assignment would not clear systemd's ordering list.
    sudo install -D -m 0644 /dev/null \
      /etc/systemd/system/nvidia-cdi-refresh.service.d/10-container-engines.conf
    sudo systemctl daemon-reload
  fi
fi
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
  # AWS DLAMI: this preference pins nvidia-driver* to apt priority -1, causing
  # "Package 'nvidia-driver-580' has no installation candidate" despite the
  # package being present in the repositories. Retries cannot fix that policy.
  # Remove only this pin when changing drivers, then refresh package metadata.
  # rm -f handles an absent AWS preference file; existing 580 hosts skip it.
  sudo rm -f /etc/apt/preferences.d/00-dlami-block-nvidia-driver
  sudo apt-get update
  # Crusoe: its installed 565 driver packages were held, preventing apt from
  # replacing them with 580. This base also holds container-toolkit packages
  # and many uninstalled NVIDIA package names. Select only held AND installed
  # driver components (dpkg status "hi"); avoid a blanket NVIDIA unhold.
  mapfile -t HELD_DRIVER_PACKAGES < <(
    dpkg-query -W -f='${db:Status-Abbrev}\t${binary:Package}\n' 'nvidia-*' 2>/dev/null |
      awk '$1 == "hi" && $2 ~ /^nvidia-((compute-utils|dkms|driver|fabricmanager|firmware|headless|kernel-common|kernel-source|kernel-open|open|utils)-[0-9]|modprobe(:|$)|prime(:|$)|settings(:|$))/ { print $2 }'
  )
  if [ "${#HELD_DRIVER_PACKAGES[@]}" -gt 0 ]; then
    echo "[setup] releasing installed driver holds: ${HELD_DRIVER_PACKAGES[*]}"
    sudo apt-mark unhold "${HELD_DRIVER_PACKAGES[@]}"
  fi
  # Crusoe: after releasing the holds, dpkg still failed because
  # libnvidia-extra-565 and the new libnvidia-gl-580 both owned
  # /usr/lib/x86_64-linux-gnu/gbm/nvidia-drm_gbm.so. Apt's dependency resolver
  # did not catch this unpack-time collision. Remove installed obsolete extras
  # before installing 580, while retaining the target branch's extra package.
  mapfile -t OLD_DRIVER_EXTRAS < <(
    dpkg-query -W -f='${db:Status-Status}\t${binary:Package}\n' 'libnvidia-extra-*' 2>/dev/null |
      awk -v keep="libnvidia-extra-$DRIVER_BRANCH" '$1 == "installed" && $2 !~ ("^" keep "(:|$)") { print $2 }'
  )
  if [ "${#OLD_DRIVER_EXTRAS[@]}" -gt 0 ]; then
    sudo env DEBIAN_FRONTEND=noninteractive apt-get remove -y "${OLD_DRIVER_EXTRAS[@]}"
  fi
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
#
# AWS/GCP: host nvidia-smi can pass while a persistent CDI specification still
# references removed 595 libraries. Wait for Brev's refresh/Docker restart,
# then regenerate an existing /etc/cdi/nvidia.yaml before creating containers.
# Run generation only after nvidia-smi passes: during the pre-reboot driver
# mismatch, the toolkit cannot reliably inspect the newly installed driver.
# Bases without this Brev CDI file skip the extra generation step.
sudo tee "/etc/systemd/system/$SERVICE_NAME" >/dev/null <<EOF
[Unit]
Description=Isaac Lab 2.3.2 Extended with ROS 2 Jazzy
Wants=docker.service network-online.target
After=docker.service network-online.target $CDI_REFRESH_AFTER

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$APP_DIR
ExecStartPre=/usr/bin/nvidia-smi
ExecStartPre=/bin/sh -c 'if [ -f /etc/cdi/nvidia.yaml ]; then /usr/bin/nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml; fi'
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

  # Keep the one-minute delay so Brev can finish recording setup completion.
  set_state "rebooting"
  # Lambda: shutdown resolves to shutdown.lambda, which returns success without
  # scheduling a reboot. That left setup at "rebooting" with the old 570 module
  # and new 580 userspace (NVML mismatch). A timer invoking systemctl reboot
  # bypasses that wrapper while preserving the delay.
  sudo systemd-run --unit=isaac-lab-ex-ros2-reboot --on-active=1m \
    --timer-property=AccuracySec=1s /usr/bin/systemctl reboot
  echo "Setup complete. The VM will reboot in approximately one minute."
else
  set_state "starting"
  # On setup reruns, start would leave an already-active oneshot unchanged.
  # Restart so the updated GPU/CDI prechecks and Compose command execute even
  # when this VM was already marked ready before the script was updated.
  sudo systemctl restart "$SERVICE_NAME"
  set_state "ready"
  echo "Setup complete. The application is running; no reboot required."
fi
