# Isaac Lab (Extended) with ROS 2

> Experimental: These unofficial Docker images are under active development, with more thorough testing planned in the near future.

This is a series of unofficial Docker images for Isaac Lab (Extended) with ROS 2 installed on top of the Ubuntu 24.04 base image. "Extended" refers to the additional built-in support for Jupyter Lab, VS Code Server, TigerVNC, noVNC, and OpenSSH Server. The instructions cover running the images locally, on Run:ai, and on Brev, but they can be easily adapted to other platforms or re-built with other base images.

If you encounter any issues or have any questions, please [open an issue](https://github.com/j3soon/runai-isaac/issues).

## Build (Optional)

> Skip this section if you want to use our pre-built docker images on Docker Hub.

Build the docker image:

```sh
# Isaac Lab 2.3.2 (Isaac Sim 5.1.0) + ROS 2 Jazzy
docker build -t j3soon/runai-isaac-lab-ex:2.3.2-ros2-jazzy -f docker/isaac-lab-ex-ros2/Dockerfile_2_3_2_ros2_jazzy .
docker push j3soon/runai-isaac-lab-ex:2.3.2-ros2-jazzy
# Isaac Lab 3.0.0-beta2 (Isaac Sim 6.0.0) + ROS 2 Jazzy
docker build -t j3soon/runai-isaac-lab-ex:3.0.0-beta2-ros2-jazzy -f docker/isaac-lab-ex-ros2/Dockerfile_3_0_0_beta2_ros2_jazzy .
docker push j3soon/runai-isaac-lab-ex:3.0.0-beta2-ros2-jazzy
# Isaac Lab 3.0.0-beta2.patch1 (Isaac Sim 6.0.1) + ROS 2 Jazzy
docker build -t j3soon/runai-isaac-lab-ex:3.0.0-beta2.patch1-ros2-jazzy -f docker/isaac-lab-ex-ros2/Dockerfile_3_0_0_beta2_patch1_ros2_jazzy .
docker push j3soon/runai-isaac-lab-ex:3.0.0-beta2.patch1-ros2-jazzy
```

> **Note:** These images are self-contained (Ubuntu 24.04 base, not the official Isaac Lab container) and download Isaac Sim (~10 GB) during the build. Build time is significantly longer than the other variants. They include Isaac Lab and ROS 2 Jazzy.

## Run:ai

> Skip this section if you're not using Run:ai.

Refer to [Isaac Lab (Extended) Interactive Workspace](../isaac-lab-ex/README.md) for Run:ai setup instructions. You only need to change the image URL to one of the ROS 2 variants below:

| Isaac Lab | Isaac Sim | ROS 2 | Image URL |
|-----------|-----------|-------|-----------|
| 2.3.2 | 5.1.0 | Jazzy | j3soon/runai-isaac-lab-ex:2.3.2-ros2-jazzy |
| 3.0.0-beta2 | 6.0.0 | Jazzy | j3soon/runai-isaac-lab-ex:3.0.0-beta2-ros2-jazzy |
| 3.0.0-beta2.patch1 | 6.0.1 | Jazzy | j3soon/runai-isaac-lab-ex:3.0.0-beta2.patch1-ros2-jazzy |

## Brev

> Skip this section if you're not using Brev.

Use Brev VM Mode when the host NVIDIA driver must be selected explicitly. For Isaac Lab 2.3.2 (Isaac Sim 5.1.0), the setup script installs Ubuntu's packaged NVIDIA 580 driver, downloads the pinned Compose file, enables the application as a systemd service, attempts `docker compose up -d`, and schedules a reboot.

1. Create a Brev Launchable using **VM Mode**. Keep the default Brev software environment so Docker, Docker Compose, and NVIDIA Container Toolkit are available.
1. Add the contents of [`brev_setup_2_3_2_ros2_jazzy.sh`](./brev_setup_2_3_2_ros2_jazzy.sh) as the VM setup script.
1. Configure the ports or Secure Links you need from the Compose file: SSH `2222`, VNC `5900`, noVNC `6080`, VS Code `8080`, and JupyterLab `8888`.
1. Deploy the Launchable. The setup script schedules a reboot approximately one minute after it completes. A warning from the initial Compose startup can be expected while the newly installed userspace driver and the still-loaded kernel module differ.
1. Reconnect after the reboot and verify the driver and application:

   ```sh
   nvidia-smi
   sudo systemctl status isaac-lab-ex-ros2.service
   sudo docker compose \
     --project-name isaac-lab-ex-ros2 \
     -f /opt/isaac-lab-ex-ros2/compose.yaml \
     -f /opt/isaac-lab-ex-ros2/compose.override.yaml \
     ps
   ```

The systemd unit retries until the GPU driver is ready, while Compose's `restart: unless-stopped` policy keeps the container running across later Docker daemon and VM restarts. The host workspace is `/workspace`.

## Local

```sh
# Ref: https://docs.isaacsim.omniverse.nvidia.com/latest/installation/install_container.html#container-deployment
# Ref: https://github.com/j3soon/docker-isaac-sim
mkdir -p ~/docker/isaac-sim/cache/main/ov
mkdir -p ~/docker/isaac-sim/cache/main/warp
mkdir -p ~/docker/isaac-sim/cache/computecache
mkdir -p ~/docker/isaac-sim/config
mkdir -p ~/docker/isaac-sim/data/documents
mkdir -p ~/docker/isaac-sim/data/Kit
mkdir -p ~/docker/isaac-sim/logs
mkdir -p ~/docker/isaac-sim/pkg
sudo chown -R 1234:1234 ~/docker/isaac-sim

xhost +local:docker
docker run --rm -it --gpus all -e "ACCEPT_EULA=Y" \
  -p 12222:22 -p 15900:5900 -p 16080:6080 -p 18888:8888 -p 18080:8080 \
  -e "PRIVACY_CONSENT=Y" \
  -v ~/docker/isaac-sim/cache/main:/isaac-sim/.cache:rw \
  -v ~/docker/isaac-sim/cache/computecache:/isaac-sim/.nv/ComputeCache:rw \
  -v ~/docker/isaac-sim/logs:/isaac-sim/.nvidia-omniverse/logs:rw \
  -v ~/docker/isaac-sim/config:/isaac-sim/.nvidia-omniverse/config:rw \
  -v ~/docker/isaac-sim/data:/isaac-sim/.local/share/ov/data:rw \
  -v ~/docker/isaac-sim/pkg:/isaac-sim/.local/share/ov/pkg:rw \
  -v $(pwd):/app \
  j3soon/runai-isaac-lab-ex:3.0.0-beta2.patch1-ros2-jazzy  # or :3.0.0-beta2-ros2-jazzy / :2.3.2-ros2-jazzy
```

You can also use the Docker Compose files:

```sh
docker compose -f docker/isaac-lab-ex-ros2/compose_3_0_0_beta2_patch1_ros2_jazzy.yaml up
```

## Developer Notes

We intentionally install Isaac Sim via binary instead of pip, since the accompanied source code and example code can greatly help AI agents to write new code.

Isaac Lab is cloned from source and installed via `isaaclab.sh --install`, so the full codebase is available at `/root/IsaacLab` inside the container.
