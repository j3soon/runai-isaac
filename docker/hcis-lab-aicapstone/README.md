# HCIS-Lab AICapstone

This page is part of the sample applications guide. Follow [README](../../README.md) first and stop interactive workloads when finished.

(Optional) Create a docker image for [HCIS-Lab/aicapstone](https://github.com/HCIS-Lab/aicapstone), an imitation-learning pipeline that generates synthetic Franka manipulation demonstrations in Isaac Lab and records them as LeRobot datasets. Each task ships preconfigured domain randomization, so object poses are re-randomized at every environment reset and no recorded pose file is needed.

This image covers **data generation only** — upstream's [Run Data Generation](https://github.com/HCIS-Lab/aicapstone/blob/9dd61f693f2db770338ce84fdd232dd7040c9555/docs/getting_started.md#run-data-generation) step. See [Scope](#scope) for what is deliberately left out.

> This image is documented for **Brev**, not Run:ai.

## Build

```sh
docker build -f docker/hcis-lab-aicapstone/Dockerfile . -t j3soon/runai-hcis-lab-aicapstone:latest
```

To publish:

```sh
docker push j3soon/runai-hcis-lab-aicapstone:latest
```

Upstream publishes no tags or releases, so this image is versioned only by `latest`. The reproducibility guarantee lives in the Dockerfile's pins rather than in the image tag — to identify which upstream commit a running image was built from, read it back out of the image:

```sh
docker run --rm j3soon/runai-hcis-lab-aicapstone:latest \
  git -C /workspace/aicapstone rev-parse HEAD
```

`docker/hcis-lab-aicapstone/Dockerfile` is a self-contained local variant that clones the upstream repo at a pinned commit during the build, since the upstream Dockerfile `COPY`s from its own working tree (`dependencies/IsaacLab`, a git submodule, and `packages/simulator`). It also bakes in the whole project tree, because upstream's `make launch-isaaclab-*` targets bind-mount the host clone over `/workspace/aicapstone` at run time and this image has no such mount.

It uses upstream's own base and stack rather than this repository's usual `nvcr.io/nvidia/isaac-lab:X` images: `nvidia/cuda:12.8.1-devel-ubuntu22.04` with Isaac Sim 5.1.0 installed from pip (`isaacsim[all,extscache]==5.1.0`), Isaac Lab built from the pinned submodule, and PyTorch 2.7.0 on CUDA 12.8.

The USD scenes, object meshes, and textures under `packages/simulator/assets/` are committed as plain git blobs, so unlike [Sim-to-Real SO-101 Workshop](../sim-to-real-so101-workshop/README.md) there is no Git LFS step and no pointer-file trap.

### Pins

Upstream publishes no tags or releases, so `main` is pinned by commit:

| Component | Pin | Note |
| --- | --- | --- |
| `HCIS-Lab/aicapstone` | `9dd61f693f2db770338ce84fdd232dd7040c9555` | `main`, 2026-08-04 |
| `dependencies/IsaacLab` | `4df6560e187f2cc66685b41b21b259f4485d0c22` | Recorded by the submodule; restored by `git submodule update` |
| `LightwheelAI/leisaac` | `24d3bcd3f1e4585740fc79921782c41617237812` | **Local addition**, see below |

> `packages/simulator/pyproject.toml` declares `leisaac @ git+https://github.com/LightwheelAI/leisaac.git#subdirectory=source/leisaac` with **no ref**, so upstream resolves it to whatever LightwheelAI's default branch points at and the same `docker build` produces a different image over time. The Dockerfile pins it to the commit that branch currently resolves to, which is what an unpinned upstream build gets today.
>
> Do not "fix" this to the newest tag. `v0.4.0` is `1651c321e9b0c1bb54233211fc7b3cd70d8373d5`, which is *older* than the branch head, so pinning the tag would silently change behavior rather than freeze it.

## Tasks

| Task ID | Scene |
| --- | --- |
| `HCIS-CupStacking-SingleArm-v0` | Kitchen |
| `HCIS-CutleryArrangement-SingleArm-v0` | Dining room |
| `HCIS-ToyBlocksCollection-SingleArm-v0` | Living room |

All three are registered in `packages/simulator/src/simulator/tasks/`. Upstream's `private_tasks/` directory is an empty, gitignored extension point resolved by `simulator/tasks/external.py`; it ships no tasks and nothing here depends on it.

## Data Generation

Upstream's documented command targets a GlowsAI VNC desktop on `DISPLAY=:1`. Two changes are needed anywhere without that display:

- **Add `--headless`.** `AppLauncher.add_app_launcher_args(parser)` provides it; upstream omits it only because GlowsAI has a display. `--enable_cameras` still renders offscreen.
- **Mount a host directory at `/root/.cache/huggingface`.** The recorder writes to `~/.cache/huggingface/lerobot/${HF_USER}/<repo_id>/`, which is inside the container. Under `docker run --rm` the dataset is deleted along with the container.

```sh
mkdir -p artifacts/hcis-lab-aicapstone/hf-cache
docker run --rm --gpus all --ipc=host \
  --ulimit memlock=-1 --ulimit stack=67108864 --shm-size=16g \
  -e HF_USER=<your-huggingface-username> \
  -v "$PWD/artifacts/hcis-lab-aicapstone/hf-cache:/root/.cache/huggingface" \
  j3soon/runai-hcis-lab-aicapstone:latest \
  python scripts/datagen/generate.py \
      --task HCIS-CupStacking-SingleArm-v0 \
      --num_envs 1 \
      --device cuda \
      --headless \
      --enable_cameras \
      --record \
      --use_lerobot_recorder \
      --lerobot_dataset_repo_id <your-huggingface-username>/<repo_id> \
      --num_demos 20
```

`--num_demos` sets the number of randomized episodes to run, and **only successful episodes are exported**, so the recorded episode count is normally lower than `--num_demos`. Check the exported count rather than assuming it matches.

### `--num_demos N` exports only N-1 episodes

**The final episode is always dropped, and the script reports full success anyway.** Ask for one more episode than you need, and verify the count in `meta/info.json` rather than trusting the console tally.

Measured at this pin on `HCIS-CupStacking-SingleArm-v0`:

| `--num_demos` | Console output | `meta/info.json` | Result |
| ---: | --- | --- | --- |
| 1 | `[Data Usage]1/1 success.` | `total_episodes: 0`, `total_frames: 0` | **Empty dataset**: no `data/`, no `videos/` |
| 3 | `[Data Usage]3/3 success.` | `total_episodes: 2`, `total_frames: 1010` | 2 episodes exported, 3rd dropped |

The cause is an interaction between two upstream files. `LeRobotRecorderManager.export_episodes()` flushes the episode buffer to disk, but Isaac Lab only calls it on **environment reset**. In `scripts/datagen/generate.py`, the branch that ends the run returns before its `env.reset()`:

```python
if next_episode_idx >= total_episodes:
    print(f"Completed all {total_episodes} episodes. Exiting the app.")
    return next_episode_idx, current_recorded_demo_count, start_record_state, True, success
env.reset()   # never reached for the last episode
```

The `finally` block does call `recorder_manager.finalize()`, but that only closes out the dataset — it does not flush the pending episode, so the last episode's frames are never consolidated into `data/*.parquet` or `videos/*.mp4`.

The tell-tale signs, all present in a run that exits 0:

- The `Recorded N successful demonstrations.` line never prints, because `exported_successful_episode_count` stays behind the state machine's own tally.
- An orphaned `images/observation.images.*/episode-<N-1>/` directory holds the dropped episode's staged PNG frames, with no matching row in the parquet.

> `[Data Usage]N/N success.` is the **state machine's** tally of task completion, not a count of exported episodes. Do not read it as a dataset size.

No Hugging Face token is needed to generate: `--lerobot_dataset_repo_id` only names the dataset, and nothing contacts the Hub until upload. To upload afterwards, see [upstream's instructions](https://github.com/HCIS-Lab/aicapstone/blob/9dd61f693f2db770338ce84fdd232dd7040c9555/docs/getting_started.md#upload-the-generated-dataset); pass a token by environment variable rather than running `hf auth login`, which is interactive.

The container writes as root, so the mounted cache ends up root-owned. Reclaim it with:

```sh
docker run --rm -v "$PWD/artifacts/hcis-lab-aicapstone:/out" \
  j3soon/runai-hcis-lab-aicapstone:latest chown -R $(id -u):$(id -g) /out
```

> Environment command:

> ```
> /run.sh --shell "exec python scripts/datagen/generate.py --task HCIS-CupStacking-SingleArm-v0 --num_envs 1 --device cuda --headless --enable_cameras --record --use_lerobot_recorder --lerobot_dataset_repo_id ${HF_USER}/<repo_id> --num_demos 20"
> ```
>
> `--shell` is required here because the command uses `${HF_USER}`; without it `/run.sh` word-splits only and the variable arrives literally. The image installs its Python packages into the system interpreter, so use a plain `python` and `python -m pip install ...` when adding packages — there is no venv and no `python.sh` wrapper.

## Verified locally

On an NVIDIA RTX PRO 6000 Blackwell (97887 MiB, driver 580.173.02), image built at 18.9GB. Driver 580 is the branch Isaac Sim 5.1.0 is tested against, so this matches the intended Brev target.

The `--num_demos 3` run above produced a structurally complete LeRobot v3.0 dataset for its two exported episodes:

- `data/chunk-000/file-000.parquet` — 1010 rows, `episode_index` `[0, 1]`, action dim 8, state dim 9.
- `videos/observation.images.{front,wrist}/chunk-000/file-000.mp4` — 640x480, 1010 frames each, matching the parquet row count.
- `meta/` — `info.json`, `stats.json`, `tasks.parquet`, `episodes/`.
- `robot_type: franka_panda`, `fps: 30`, two camera streams.

Video content was checked rather than assumed: sampled frames have a per-frame standard deviation of 21-31, so they hold real rendered scene content. A blank or all-black export would sit near zero, which is the failure mode Isaac Sim capture is prone to.

Roughly 190MB on disk for two episodes (~95MB per episode), and 505 frames per episode at 30fps. Budget disk accordingly: the documented 20-demo run is on the order of 2GB.

The build needs **no GPU** — it is entirely `apt` and `pip` — which is what makes prebuilding worthwhile before touching a billed instance. Measured layer times: Isaac Sim 5.1.0 pip install 428s, `isaaclab.sh --install` 429s, everything else under a minute each.

Evidence, including full logs, is under `artifacts/hcis-lab-aicapstone/raw/evidence/9dd61f6/` (gitignored).

## Brev

> Skip this section if you're not using Brev.

> **Status: blocked, with a known cause.** A full deployment on `g6e.xlarge` (L40S) reached a healthy VM with driver 580.178.04 and the image pulled, but **Isaac Sim cannot start there**: this image's Ubuntu 22.04 base ships a Vulkan loader too old to load that driver's ICD, so the renderer fails with `Failed to create any GPU devices`. The host driver is fine — the Isaac Lab (Extended) with ROS 2 image, on an `ubuntu:24.04` base, renders correctly on an identical instance. See [Vulkan fails on the Ubuntu 22.04 base](#vulkan-fails-on-the-ubuntu-2204-base) below.

Use **VM Mode**, which is the only Brev runtime mode that lets the host NVIDIA driver version be selected. That matters here: this image pins Isaac Sim 5.1.0, and [Isaac Sim 5.1.0 is tested against Linux driver 580.65.06](https://docs.isaacsim.omniverse.nvidia.com/5.1.0/installation/requirements.html), while Brev's AWS base image ships the 595 branch.

The 595 incompatibility is a known upstream defect, not just a local observation: [IsaacSim#537](https://github.com/isaac-sim/IsaacSim/issues/537) reports driver 595.79 making Isaac Sim 5.1.0 fail to detect the CUDA device and crash during RTX plugin initialization, with "downgrading the NVIDIA driver to version 580 resolves the issue." This repository measured the same thing independently — see the [Isaac Lab (Extended) with ROS 2 Brev notes](../isaac-lab-ex-ros2/README.md#brev). Note the requirements page states no *maximum* driver version, so the constraint is not discoverable there.

Install branch 580 and reboot, exactly as [`brev_setup_2_3_2_ros2_jazzy.sh`](../isaac-lab-ex-ros2/brev_setup_2_3_2_ros2_jazzy.sh) does.

**Prefer prebuilding.** This image builds Isaac Sim from pip and takes far longer on a rented 4 vCPU instance than on a workstation, and the build needs no GPU at all — it is pure `apt` and `pip`. Build it wherever CPU is cheap, push it to a registry, and have the instance pull it. That keeps the billed instance busy only for the pull and the run.

Sizing follows the same measurements as the Isaac Lab (Extended) image: use a **256GiB** disk, and note that `brev create` cannot set the disk size at all (it hardcodes `diskStorage: 120Gi`), so create through the API or a Launchable. See the [`deploy-brev-launchable` skill](../../skills/deploy-brev-launchable/SKILL.md) and its [Brev deployment notes](../../skills/deploy-brev-launchable/references/brev-notes.md) for instance creation, the SSH relay, and cleanup.

Two Brev-specific traps for this image in particular:

- **Do not use upstream's `make launch-isaaclab-glowsai-4090` / `-l40s` targets.** They bind-mount `/home/glows/.Xauthority` and `/opt/VirtualGL`, which do not exist on a Brev instance. Docker silently creates the missing paths as empty *directories*, and the accompanying empty `/usr/share/vulkan/icd.d` mount can mask the ICD the NVIDIA container toolkit injects, breaking Vulkan for `--enable_cameras`. Use the `docker run` above.
- **Verify Vulkan before a long run**, since `--enable_cameras` needs it: `docker run --rm --gpus all j3soon/runai-hcis-lab-aicapstone:latest vulkaninfo --summary`. On a working host this lists the GPU with `vendorID = 0x10de`; on the failed deployment below it errored instead.

### Vulkan fails on the Ubuntu 22.04 base

Measured 2026-08-17 on `g6e.xlarge` (L40S), 256GiB disk, with the driver-580 setup script.

The deployment itself was clean and reproduced this repository's existing measurements:

| Phase | Time |
| --- | ---: |
| create to `RUNNING` | ~18 min |
| `nvidia-driver-580` install | ~5 min |
| image pull (18.87GB) | ~12.5 min |
| reboot to `ready` | ~1 min |
| **create to `ready`** | **~40 min** |

Driver went 595.91.07 to 580.178.04, the reboot loaded it, `nvidia-smi` and CUDA worked inside the container, and disk sat at 105G of 249G used. Then Isaac Sim failed to start:

```
[carb.graphics-vulkan.plugin] vkCreateInstance failed. Vulkan 1.1 is not supported, or your driver requires an update.
[carb.graphics-vulkan.plugin] VkResult: ERROR_INCOMPATIBLE_DRIVER
[omni.gpu_foundation_factory.plugin] Failed to create any GPU devices, including an attempt with compatibility mode.
```

**This is the image's Vulkan loader, not the host driver.** A control run settles it: the [Isaac Lab (Extended) with ROS 2](../isaac-lab-ex-ros2/README.md) 2.3.2 image, deployed from its Launchable onto an identical `g6e.xlarge` with the same setup script and the same resulting driver 580.178.04, reports `deviceName = NVIDIA L40S` from `vulkaninfo`, logs `Graphics API: Vulkan`, and completes `Isaac-Cartpole-RGB-Camera-Direct-v0 --enable_cameras` environment setup with no Vulkan errors at all.

The only material difference is the base image. This image inherits `nvidia/cuda:12.8.1-devel-ubuntu22.04`, whose libvulkan1 is ~1.3.204 from early 2022 and cannot load the 580.178.04 ICD; the ROS 2 image is built on `ubuntu:24.04`. The error string — `Could not get 'vkCreateInstance' via 'vk_icdGetInstanceProcAddr'` — is the loader/ICD interface-version mismatch signature, which reads misleadingly like a driver fault.

> Testing Vulkan on the *host* is not a valid check: `vulkaninfo` installed from the host's own archive exercises that distribution's loader and reproduces the same error, which is what first led this investigation to blame the driver.

The likely fix is to install a newer Vulkan loader into this image, or move it to an Ubuntu 24.04 base — both deviations from upstream's Dockerfile, and neither is tested here. Note the image works unmodified on a local Ubuntu 22.04 host running driver 580.173.02, so the incompatibility is specific to certain driver builds rather than universal.

One cheaper mitigation is worth trying first, though it is **untested here**: Kit runs its own driver-version check, and drivers above 535.255 [report their version incorrectly through Vulkan](https://github.com/isaac-sim/IsaacLab/issues/3604), so Kit can reject a working driver. Disable it with `--/rtx/verifyDriverVersion/enabled=false`. That only helps if the Vulkan loader can create an instance at all — here `vulkaninfo` fails inside the same container, which puts the fault below Kit, so this flag most likely will not be sufficient on its own.

These were each checked and are **not** the cause:

- All GL libraries are mounted into the container (`libGLX_nvidia.so.580.178.04`, `libnvidia-glvkspirv.so.580.178.04`, `libnvidia-glcore.so.580.178.04`), and `NVIDIA_DRIVER_CAPABILITIES` is `all`.
- The ICD JSON is well-formed and points at `libGLX_nvidia.so.0`. Mounting the host's `/usr/share/vulkan/icd.d` (as upstream's Makefile does) and setting `VK_ICD_FILENAMES` both fail identically.
- `libGLX_nvidia.so.0` dlopens successfully and *does* export `vk_icdGetInstanceProcAddr`; the loader's call for `vkCreateInstance` returns null, so the ICD is refusing to initialize.
- Device nodes (`nvidia0`, `nvidiactl`, `nvidia-uvm`, `nvidia-modeset`) and kernel modules (`nvidia`, `nvidia_uvm`, `nvidia_drm`, `nvidia_modeset`, proprietary, 580.178.04) are all present.
- The GPU is `Pass-Through` with `Compute Mode: Default` — not vGPU or MIG.

A failed run also **hangs rather than exiting**: the Kit process stayed alive for 20+ minutes after the error and had to be killed. Do not wait on process exit as a completion signal.

Two untested paths remain, in the order worth trying:

1. **Keep Brev's stock 595 driver** and check whether Isaac Sim 5.1.0 actually fails on it for *this* image. The "5.1.0 fails on 595" result recorded for [Isaac Lab (Extended) with ROS 2](../isaac-lab-ex-ros2/README.md#brev) was measured on a different image, and a provider's own base image is likely to ship a working Vulkan stack. If 595 works here, the whole driver downgrade — and its reboot — is unnecessary.
2. **Install 580 from NVIDIA's `.run` installer** rather than the Ubuntu package, in case the packaged build omits a working Vulkan ICD.

## Scope

Only the data-generation surface is covered.

- **Works**: headless data generation for the three tasks above, writing LeRobot datasets.
- **Not covered**: `scripts/rollout.py` policy evaluation needs a trained checkpoint, and `scripts/teleop.py` needs a keyboard and a display. Upstream directs training (`lerobot-train`) to the **host** rather than into this container, so it is not installed here.
