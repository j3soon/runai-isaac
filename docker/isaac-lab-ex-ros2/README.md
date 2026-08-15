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

Brev provides four runtime modes: **VM Mode**, **Single Container**, **Docker Compose**, and **Single-node Kubernetes**. VM Mode is the only one that allows the host NVIDIA driver version to be selected and installed. The other three modes run on the provider-managed host driver; changing CUDA libraries inside a container does not replace that host kernel driver.

This matters for reproducibility across older Isaac releases. [Isaac Lab 2.3.2 supports Isaac Sim only through 5.1.0](https://github.com/isaac-sim/IsaacLab/blob/v2.3.2/README.md), and our Isaac Sim 5.1.0 workload fails with NVIDIA driver 595. NVIDIA tested Isaac Sim 5.1.0 with Linux driver [580.65.06](https://docs.isaacsim.omniverse.nvidia.com/5.1.0/installation/requirements.html), so its setup script installs Ubuntu's packaged 580 driver. It then downloads the version-specific Compose file from this repository's `main` branch, pulls the image, enables the application as a systemd service, and schedules a reboot. VM Mode prevents a provider driver upgrade from silently making preserved 2.3.2 or 5.1.0 containers unusable.

Isaac Lab 3.0.0-beta2.patch1 (Isaac Sim 6.0.1) pins the 595 driver branch instead. Brev's base image already ships 595, so that setup script normally installs no driver and skips the reboot, leaving only the image pull.

> The 2.3.2 deploy takes about 30 minutes and looks broken until its reboot. See the [`deploy-brev-launchable` skill](../../skills/deploy-brev-launchable/SKILL.md) and its [Brev deployment notes](../../skills/deploy-brev-launchable/references/brev-notes.md) for the measured timeline, verification, and CLI behavior.

| Isaac Lab | Isaac Sim | ROS 2 | Brev URL |
|-----------|-----------|-------|----------|
| 2.3.2 | 5.1.0 | Jazzy | [![ Click here to deploy.](https://brev-assets.s3.us-west-1.amazonaws.com/nv-lb-dark.svg)](https://brev.nvidia.com/launchable/deploy?launchableID=env-3HmXnNzoex3D9hUuIyUDkeFJbT4) |
| 3.0.0-beta2.patch1 | 6.0.1 | Jazzy | [![ Click here to deploy.](https://brev-assets.s3.us-west-1.amazonaws.com/nv-lb-dark.svg)](https://brev.nvidia.com/launchable/deploy?launchableID=env-3Hp8A2xYfls4xle14W0891vLF4p) |

1. Click one of the Brev badges above to navigate to the Brev launchable page.
1. (Optional) If you haven't logged in to Brev, click `Sign In`, you will be prompted to log in or register. After logging in, you will be redirected back to the launchable page.
1. (Optional) If you have multiple Brev organizations, make sure to select the correct one from the dropdown menu in the top right corner of the page.
1. Click `Deploy Launchable`, and wait for provisioning to complete. (If it failed, delete and re-deploy the launchable.)
1. Click `Go to instance page` to open the Brev workspace in a new browser tab, and wait for the `script` part to switch from `Executing` to `Completed`. (You will get 404 errors if not waiting until script completes)
1. Finally, use the `novnc`, `jupyter`, or `code-server` links.

To build your own launchable, or to deploy another version:

1. Create a Brev Launchable using **VM Mode**. Keep the default Brev software environment so Docker, Docker Compose, and NVIDIA Container Toolkit are available.
1. Add the contents of the setup script for the version you want as the VM setup script: [`brev_setup_2_3_2_ros2_jazzy.sh`](./brev_setup_2_3_2_ros2_jazzy.sh) or [`brev_setup_3_0_0_beta2_patch1_ros2_jazzy.sh`](./brev_setup_3_0_0_beta2_patch1_ros2_jazzy.sh).
1. Configure the ports or Secure Links you need from the Compose file: SSH `2222`, VNC `5900`, noVNC `6080`, VS Code `8080`, and JupyterLab `8888`.
1. Deploy the Launchable. Track progress with `cat /var/lib/isaac-lab-ex-ros2-setup.state` and wait for `ready`. The 2.3.2 script installs a different driver branch than the base image provides, so it schedules a reboot once the image is pulled and `nvidia-smi` fails until then; the 3.0.0-beta2.patch1 script keeps the base image's driver and starts the application without rebooting.
1. Verify the driver and application, reconnecting first if the VM rebooted:

   ```sh
   nvidia-smi
   sudo systemctl status isaac-lab-ex-ros2.service
   sudo docker compose \
     -f /opt/isaac-lab-ex-ros2/compose.yaml \
     ps
   ```

The systemd unit retries until the GPU driver is ready, while Compose's `restart: unless-stopped` policy keeps the container running across later Docker daemon and VM restarts. The host workspace is `/workspace`.

### Verified Instance Types (2.3.2)

The 2.3.2 setup script needs no per-GPU changes: driver branch 580 covers both Ada and Turing, and the same script resolved `580.178.04` on each. Measured with 256GiB disk and 32GB RAM, running all five service probes plus Isaac Sim init and a 3-iteration cartpole training:

| Instance | GPU | VRAM | RAM | $/hr | Setup to `ready` | Cartpole fps |
|----------|-----|------|-----|------|------------------|--------------|
| `g6e.xlarge` | L40S | 46068 MiB | 32GiB | $2.23 | ~23 min | 158331 |
| `g4dn.2xlarge` | T4 | 15360 MiB | 32GiB | $0.90 | ~22 min | 119075 |

The T4 reaches about 75% of L40S throughput at roughly 40% of the cost, and 15GB of VRAM is ample for cartpole — a heavier scene may not fit. Treat small throughput differences as noise: two `g6e.xlarge` runs of the same image differed by ~6% (158331 and 168972).

> Pick x86_64. AWS `g5g.*` instances carry a T4**g** on **arm64** and cannot run this image, despite matching on GPU name, VRAM, and RAM in instance searches.

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

xhost +local:docker
docker run --rm -it --gpus all -e "ACCEPT_EULA=Y" \
  -p 12222:22 -p 15900:5900 -p 16080:6080 -p 18888:8888 -p 18080:8080 \
  -e "PRIVACY_CONSENT=Y" \
  -v ~/docker/isaac-sim/cache/main:/root/.cache:rw \
  -v ~/docker/isaac-sim/cache/computecache:/root/.nv/ComputeCache:rw \
  -v ~/docker/isaac-sim/logs:/root/.nvidia-omniverse/logs:rw \
  -v ~/docker/isaac-sim/config:/root/.nvidia-omniverse/config:rw \
  -v ~/docker/isaac-sim/data:/root/.local/share/ov/data:rw \
  -v ~/docker/isaac-sim/pkg:/root/.local/share/ov/pkg:rw \
  -v $(pwd):/app \
  j3soon/runai-isaac-lab-ex:3.0.0-beta2.patch1-ros2-jazzy  # or :3.0.0-beta2-ros2-jazzy / :2.3.2-ros2-jazzy
```

You can also use the Docker Compose files:

```sh
docker compose -f docker/isaac-lab-ex-ros2/compose_3_0_0_beta2_patch1_ros2_jazzy.yaml up

# Isaac Lab 2.3.2, with optional host-port and workspace overrides
VNC_PORT=15900 WORKSPACE_DIR="$PWD" \
  docker compose -f docker/isaac-lab-ex-ros2/compose_2_3_2_ros2_jazzy.yaml up
```

In a noVNC terminal, launch Isaac Sim with its bundled Python 3.11 ROS 2 Jazzy libraries:

```sh
/root/isaacsim/isaac-sim.sh
```

For external ROS 2 CLI commands, open a separate terminal and explicitly activate the system Python 3.12 Jazzy environment:

```sh
source /opt/ros/jazzy/setup.bash
source /usr/share/colcon_argcomplete/hook/colcon-argcomplete.bash
ros2 topic list
```

## Developer Notes

We intentionally install Isaac Sim via binary instead of pip, since the accompanied source code and example code can greatly help AI agents to write new code.

Isaac Lab is cloned from source and installed via `isaaclab.sh --install`, so the full codebase is available at `/root/IsaacLab` inside the container.

For the 2.3.2 image, `isaacsim_ml_archive.pth` is required. Isaac Sim 5.1 does not put `exts/omni.isaac.ml_archive/pip_prebundle` on embedded Python's initial `sys.path`, although Torch and its bundled CUDA libraries are stored there. Python processes the `.pth` file during site initialization, before Kit extensions import Torch. In a clean A/B build, removing it produced 203 Kit errors and 104 tracebacks, including 141 reports that `libcublas` could not be found; restoring it reduced all three counts to zero and allowed the ROS bridge and `rclpy` to load.
