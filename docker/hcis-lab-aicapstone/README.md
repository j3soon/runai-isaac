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

It uses upstream's own stack rather than this repository's usual `nvcr.io/nvidia/isaac-lab:X` images: Isaac Sim 5.1.0 installed from pip (`isaacsim[all,extscache]==5.1.0`), Isaac Lab built from the pinned submodule, and PyTorch 2.7.0 on CUDA 12.8.

The base matches upstream (`nvidia/cuda:12.8.1-devel-ubuntu22.04`). The only addition is a GLVND EGL vendor registration, which the NVIDIA container toolkit does not inject and which `--enable_cameras` needs on some hosts — see [The EGL vendor file is required](#the-egl-vendor-file-is-required). A 24.04 base was trialled while diagnosing that failure and made no difference; it is not needed.

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

> **Status: works.** Validated end to end on both AWS `g6e.xlarge` and shadeform `massedcompute_L40S`.
>
> An earlier version of this image failed on AWS with `Failed to create any GPU devices`. The cause was a **missing GLVND EGL vendor registration**, now shipped in the Dockerfile — see [The EGL vendor file is required](#the-egl-vendor-file-is-required).

Use **VM Mode**, which is the only Brev runtime mode that lets the host NVIDIA driver version be selected. That matters here: this image pins Isaac Sim 5.1.0, and [Isaac Sim 5.1.0 is tested against Linux driver 580.65.06](https://docs.isaacsim.omniverse.nvidia.com/5.1.0/installation/requirements.html), while Brev's AWS base image ships the 595 branch.

The 595 incompatibility is a known upstream defect, not just a local observation: [IsaacSim#537](https://github.com/isaac-sim/IsaacSim/issues/537) reports driver 595.79 making Isaac Sim 5.1.0 fail to detect the CUDA device and crash during RTX plugin initialization, with "downgrading the NVIDIA driver to version 580 resolves the issue." This repository measured the same thing independently — see the [Isaac Lab (Extended) with ROS 2 Brev notes](../isaac-lab-ex-ros2/README.md#brev). Note the requirements page states no *maximum* driver version, so the constraint is not discoverable there.

[`brev_setup.sh`](./brev_setup.sh) in this directory does that: it detects the loaded driver branch, installs 580 and reboots only when needed, pulls the image, and publishes a phase file. Paste it into a Launchable's VM setup script, then track progress with `cat /var/lib/aicapstone-setup.state` and wait for `ready`.

> The script waits for the apt/dpkg lock before its first `apt-get`. Brev's own provisioning runs apt concurrently, and a `set -e` script that skips this dies on `Could not get lock /var/lib/apt/lists/lock`, leaving the phase file at `preparing` — which reads as a stalled instance rather than a failed one.

**Prefer prebuilding.** This image builds Isaac Sim from pip and takes far longer on a rented 4 vCPU instance than on a workstation, and the build needs no GPU at all — it is pure `apt` and `pip`. Build it wherever CPU is cheap, push it to a registry, and have the instance pull it. That keeps the billed instance busy only for the pull and the run.

Sizing follows the same measurements as the Isaac Lab (Extended) image: use a **256GiB** disk, and note that `brev create` cannot set the disk size at all (it hardcodes `diskStorage: 120Gi`), so create through the API or a Launchable. See the [`deploy-brev-launchable` skill](../../skills/deploy-brev-launchable/SKILL.md) and its [Brev deployment notes](../../skills/deploy-brev-launchable/references/brev-notes.md) for instance creation, the SSH relay, and cleanup.

Two Brev-specific traps for this image in particular:

- **Do not use upstream's `make launch-isaaclab-glowsai-4090` / `-l40s` targets.** They bind-mount `/home/glows/.Xauthority` and `/opt/VirtualGL`, which do not exist on a Brev instance. Docker silently creates the missing paths as empty *directories*, and the accompanying empty `/usr/share/vulkan/icd.d` mount can mask the ICD the NVIDIA container toolkit injects, breaking Vulkan for `--enable_cameras`. Use the `docker run` above.
- **Verify Vulkan before a long run**, since `--enable_cameras` needs it: `docker run --rm --gpus all j3soon/runai-hcis-lab-aicapstone:latest vulkaninfo --summary`. On a working host this lists the GPU with `vendorID = 0x10de`; on the failed deployment below it errored instead.

### The EGL vendor file is required

The Dockerfile writes `/usr/share/glvnd/egl_vendor.d/10_nvidia.json`, registering NVIDIA as a GLVND EGL vendor. **Do not remove it.** Upstream omits it because its target machines have a desktop driver install that provides the file; a container gets only what the NVIDIA container toolkit injects, and the toolkit injects the Vulkan ICD but **not** the EGL vendor registration.

Without it, on a host whose driver was installed by downgrading:

```
vulkaninfo -> Could not get 'vkCreateInstance' via 'vk_icdGetInstanceProcAddr' for ICD libGLX_nvidia.so.0
              vkCreateInstance failed with ERROR_INCOMPATIBLE_DRIVER
Isaac Sim  -> Failed to create any GPU devices, including an attempt with compatibility mode.
```

With it, on the same host, `vulkaninfo` reports `deviceName = NVIDIA L40S` and datagen runs. The NVIDIA Vulkan ICD reaches the GPU through EGL/GBM when there is no display, and that path needs a registered EGL vendor.

**Why it only appears on some hosts.** Brev's AWS base image ships driver 595, [Isaac Sim 5.1.0 cannot run on 595](https://github.com/isaac-sim/IsaacSim/issues/537), so the setup script installs Ubuntu's `nvidia-driver-580` over it. That downgraded host is missing pieces a normal install provides, which is what exposes the gap. On a provider whose base already ships 580 (shadeform `massedcompute_L40S`) this image worked even before the fix. The error message blames the driver and is therefore doubly misleading: the driver is a contributing condition, but the missing file is in the image.

This also explains a comparison that was confusing for a long time: this repository's [Isaac Lab (Extended) with ROS 2](../isaac-lab-ex-ros2/README.md) image rendered on the same AWS host where this one did not, at the same moment. That image writes the same EGL vendor file at build time.

**Ruled out by direct test on the failing host** — each was measured, so do not re-investigate:

- The Vulkan ICD JSON. Both images carry byte-identical ICD JSON *at runtime* (`api_version 1.4.312`); the toolkit overwrites the ROS 2 image's hand-written `1.3.194` version, so that file is not the difference.
- The Vulkan loader version (LunarG 1.4.313.0 over Ubuntu 22.04's 1.3.204.1).
- The base image and glibc. A 24.04 base (glibc 2.39, loader 1.3.275.0) changed nothing, and a bare `ubuntu:24.04` failed on that host too.
- The `undefined symbol: __malloc_hook / ErrorF` messages under `LD_DEBUG`. The **working** container emits the identical set, so they are loader noise, not a fault.
- CUDA forward-compat libraries, `LD_LIBRARY_PATH`, `mesa-vulkan-drivers`, `VK_ICD_FILENAMES`, and bind-mounting `libnvidia-api.so.1`. `libGLX_nvidia` is byte-identical to the host's in both images and `libnvidia-glcore` resolves fully in both.

### Verified Instance Types

Measured 2026-08-19 with `j3soon/runai-hcis-lab-aicapstone:latest`, one `--num_demos 3` cup-stacking datagen run per instance, 256GiB disk (625GB fixed on shadeform). Sorted by price.

| Instance | Cloud | GPU (VRAM) | vCPU | RAM | $/hr | Datagen | Wall clock | Peak RAM | Peak VRAM |
| --- | --- | --- | ---: | --- | ---: | --- | ---: | ---: | ---: |
| `n1-standard-2:nvidia-tesla-t4:1` | GCP | T4 (15360 MiB) | 2 | 8GiB | $0.53 | **fails** | - | - | - |
| `g4dn.xlarge` | AWS | T4 (15360 MiB) | 4 | 16GiB | $0.63 | passes | 745s | 7570 MiB | 4025 MiB |
| `g2-standard-4:nvidia-l4:1` | GCP | L4 (23034 MiB) | 4 | 16GiB | $0.85 | **fails** | - | - | - |
| `g4dn.2xlarge` | AWS | T4 (15360 MiB) | 8 | 32GiB | $0.90 | passes | 460s | 8128 MiB | 4025 MiB |
| `g6.xlarge` | AWS | L4 (23034 MiB) | 4 | 16GiB | $0.97 | passes | 471s | 7766 MiB | 4449 MiB |
| `massedcompute_L40S` | shadeform | L40S (46068 MiB) | 12 | 72GiB | $1.06 | passes | 193s | 10437 MiB | 5605 MiB |
| `g6e.xlarge` | AWS | L40S (46068 MiB) | 4 | 32GiB | $2.23 | passes | 492s | 7377 MiB | 5592 MiB |

**GCP does not work, and no image change can fix it.** Both GCP rows produced an empty dataset. Their hosts install a *compute-only* NVIDIA driver: `/usr/lib/x86_64-linux-gnu` contains no `libGLX_nvidia`, `libEGL_nvidia`, or `libnvidia-glcore` at all, so the container toolkit has nothing to inject and the NVIDIA Vulkan ICD cannot load. This is not specific to this image — the [Isaac Lab (Extended) with ROS 2](../isaac-lab-ex-ros2/README.md) image on the same GCP host also falls back to `llvmpipe` software rendering rather than using the GPU.

GCP itself is not the problem — its catalogue includes NVIDIA RTX Virtual Workstation types (`nvidia-l4-vws`, `nvidia-tesla-t4-vws`, `nvidia-rtx-pro-6000-vws`, ...), which Google describes as intended for "NVIDIA Omniverse simulation workloads". **Brev exposes none of them**: every GCP accelerator in `brev search gpu` is a plain compute type. So this is a Brev catalogue limitation, and running on GCP would mean provisioning a vWS instance outside Brev.

> Do not try to repair this on the host. Installing `libnvidia-gl-<branch>` on a GCP instance added the libraries but broke the NVIDIA container toolkit outright (`/run/nvidia-persistenced/socket: no such file or directory`), leaving the box unable to start GPU containers at all — strictly worse than before.

**Everything from a T4 upward works, and 16GiB of RAM is enough.** Peak host RAM stayed between 7.4 and 8.1GiB on every 4-8 vCPU instance; the 12 vCPU shadeform box peaked higher at 10.4GiB, tracking vCPU rather than GPU. Peak VRAM was 4.0GiB on T4, 4.4GiB on L4 and 5.6GiB on L40S, so the 15360 MiB T4 has ample headroom — VRAM is not the constraint for `--num_envs 1`.

**Wall clock is dominated by vCPU count, not by the GPU.** The 12 vCPU L40S finished in 193s while the 4 vCPU L40S took 492s — 2.5x slower on identical hardware otherwise. The 4 vCPU T4 was slowest at 745s, and doubling it to 8 vCPU (`g4dn.2xlarge`) cut that to 460s, beating the 4 vCPU L4. **If throughput matters, buy vCPUs rather than a bigger GPU.**

Best value is `massedcompute_L40S` at $1.06/hr: cheapest per episode, fastest, and it skips the driver downgrade and reboot entirely. Budget a retry — 2 of 4 shadeform creates failed with `build_status=CREATE_FAILED` before any relay appeared, and an immediate identical retry succeeded each time.

> Episode counts vary between runs. `--num_demos 3` normally exports 2 episodes / 1010 frames, but the shadeform run exported 1 / 505 because one episode failed its task under domain randomization. Combined with the [N-1 export bug](#--num_demos-n-exports-only-n-1-episodes), treat the exported count as `successes - 1`.

## Scope

Only the data-generation surface is covered.

- **Works**: headless data generation for the three tasks above, writing LeRobot datasets.
- **Not covered**: `scripts/rollout.py` policy evaluation needs a trained checkpoint, and `scripts/teleop.py` needs a keyboard and a display. Upstream directs training (`lerobot-train`) to the **host** rather than into this container, so it is not installed here.
