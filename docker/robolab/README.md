# RoboLab

This page is part of the sample applications guide. Follow [README](../../README.md) first and stop interactive workloads when finished.

(Optional) Create a docker image for [RoboLab](https://github.com/NVlabs/RoboLab), a task-based evaluation benchmark for robot manipulation policies built on Isaac Lab. RoboLab ships 120 benchmark tasks with automated success detection, runs multiple episodes in parallel across environments, and evaluates policies through a server-client architecture: the model runs as a standalone server and RoboLab connects to it with a lightweight inference client.

`docker/robolab/Dockerfile` is a self-contained local variant that clones the upstream repo at the pinned `v0.3.0` commit during the build, since the upstream Dockerfile copies its own working tree. It uses the `nvcr.io/nvidia/isaac-lab:2.2.0` base image, which is upstream's default `isaac50` stack (Isaac Sim 5.0 / Isaac Lab 2.2.0). The image bakes in the git-LFS asset library (objects, scenes, backgrounds, fixtures, materials, and robots), so no asset download is needed at runtime. The image is large; check its size locally after building.

> v0.3.0 changed the coordinate-frame contract: end-effector observations are now published in the robot-root frame, with a compatibility shim for older recordings (`robolab/core/logging/frame_compat.py`, and [`docs/frames.md`](https://github.com/NVlabs/RoboLab/blob/v0.3.0/docs/frames.md)). Do not compare scores across the v0.2.x and v0.3.x boundary. The release also adds the `volo` backend, per-step ground-truth state export via `--enable-gt-state`, robot-owned scene fixtures, and multi-gripper success predicates for bimanual robots.

> Isaac Sim 5.0 and 5.1 ship different PhysX builds, so contact-rich dynamics are not invariant across the two stacks. Compare benchmark results only against runs on the same stack, and replay recorded episodes on the stack they were recorded with. Upstream also supports an `isaac51` stack — the `nvcr.io/nvidia/isaac-lab:2.3.0` base image for container installs, or the `isaac51` extra (Isaac Lab 2.3.2.post1 / Isaac Sim 5.1) for native `uv` installs. This image does not cover it.

```sh
docker build -f docker/robolab/Dockerfile . -t j3soon/runai-robolab:0.3.0
docker push j3soon/runai-robolab:0.3.0
```

> Environment command:

> ```
> /run.sh "/workspace/isaaclab/_isaac_sim/python.sh -u examples/run_empty.py --headless"
> ```
>
> The `-u` flag is required for correct logging by setting unbuffered mode. RoboLab is installed into the Isaac Sim Python environment, so use `python.sh` rather than a system `python`, and `python.sh -m pip install ...` when adding packages.

## Run On Run:ai

RoboLab evaluation is a non-interactive GPU job, so create the environment as a **Workspace** with the command above, following the same steps as the [Isaac Lab Headless Workspace](../isaac-lab/README.md) guide:

- Image URL
  ```
  j3soon/runai-robolab:0.3.0
  ```
- Runtime settings
  - Command
    ```
    /run.sh "/workspace/isaaclab/_isaac_sim/python.sh -u examples/run_empty.py --headless --task BananaInBowlTask"
    ```
  - Arguments: (Keep empty)
- Security
  - Set where the UID, GID, and supplementary groups for the container should be taken from
    ```
    From the image
    ```

Select a single-GPU compute resource and the `<YOUR_LAB>-nfs` data source. RoboLab steps tasks sequentially in one simulator process and ships no distributed launcher, so extra GPUs do not speed up a single evaluation run; split the task list across several single-GPU workloads instead. A multi-GPU resource is still useful when you co-locate a policy server, which upstream places on its own GPU.

Always pass `--headless` for multi-task runs. Upstream documents a [GPU VRAM leak](https://github.com/NVlabs/RoboLab/blob/v0.3.0/docs/known_issues.md) in GUI mode that grows on every environment reload and eventually exhausts VRAM.

`--num-envs` controls how many episodes run in parallel and is the main VRAM knob. Upstream measured per-task ceilings on a 48GB GPU in the [`num_envs` ceiling guide](https://github.com/NVlabs/RoboLab/blob/v0.3.0/docs/env_vram_size_guide.md); treat those numbers as an upper bound. Upstream's [benchmark guide](https://github.com/NVlabs/RoboLab/blob/v0.3.0/docs/benchmark.md) budgets roughly 40 GPU hours for a full 120-task sweep, assuming a ~200ms policy inference step.

### Outputs and persistent storage

RoboLab always writes under `output/` inside its package directory (`/workspace/robolab/output`), which is container-local and lost when the workload stops. There is no environment variable to redirect it, so point it at the shared mount before starting a run:

```sh
mkdir -p /mnt/nfs/<YOUR_USERNAME>/robolab-output
ln -sfn /mnt/nfs/<YOUR_USERNAME>/robolab-output /workspace/robolab/output
```

Each run creates `output/<timestamp>_<policy>/` containing an `episode_results.jsonl` summary and a per-task subdirectory with `env_cfg.json` and per-episode, per-environment `log_<episode>_env<id>.json` files. Policy runs additionally write two MP4 videos per episode (observation camera and viewport camera) and the recorded HDF5 episode; `examples/run_empty.py` disables both. Reusing a folder with `--output-folder-name` resumes a run and skips completed episodes, which makes an interrupted evaluation safe to restart — this only works if the folder survives the workload, so keep it on the shared mount.

Browse results with the bundled dashboard from an interactive workload. RoboLab installs into the Isaac Sim Python environment, whose `bin` directory is not on `PATH`, so call the entry point by path:

```sh
/workspace/isaaclab/_isaac_sim/kit/python/bin/robolab-dashboard
# open http://localhost:8080
```

## Evaluate A Policy

RoboLab does not bundle model weights. The policy runs as a separate server, and `policies/<policy>/run.py` connects to it as a client:

```sh
/workspace/isaaclab/_isaac_sim/python.sh -u policies/pi0_family/run.py \
    --policy pi05 --task BananaInBowlTask --num-envs 10 --headless
```

The image includes the pinned `openpi-client` package used by the Pi0 family client. Upstream also ships clients for [GR00T](https://github.com/NVlabs/RoboLab/tree/v0.3.0/policies/gr00t), [Cosmos 3](https://github.com/NVlabs/RoboLab/tree/v0.3.0/policies/cosmos3), [DreamZero](https://github.com/NVlabs/RoboLab/tree/v0.3.0/policies/dreamzero), and [VoLo](https://github.com/NVlabs/RoboLab/tree/v0.3.0/policies/volo) under `policies/`; see [`policies/README.md`](https://github.com/NVlabs/RoboLab/blob/v0.3.0/policies/README.md) for the server setup of each backend and [`docs/policy.md`](https://github.com/NVlabs/RoboLab/blob/v0.3.0/docs/policy.md) for writing your own client.

Each RoboLab client targets a specific upstream checkpoint and server revision, so check the client's README before assuming an existing image is compatible. This repository's [Isaac GR00T N1.7](../isaac-gr00t-n1.7/README.md) image serves the GR00T client; the [N1.6](../isaac-gr00t-n1.6/README.md) image does not, being an older model version. Note that N1.7 is pinned at the untagged `GR00T N1.7 General Release` commit rather than the `n1.7-release` tag, because the tagged build predates the `msgpack_numpy` serialization this client requires and rejects its arrays as `<class 'dict'>`.

### Verified locally: Cosmos 3

The [Cosmos 3](../cosmos3/README.md) image serves `Cosmos3-Nano-Policy-DROID` over the OpenPI WebSocket protocol. Run both containers with `--net host` so the client's default `localhost:8000` resolves.

```sh
# Terminal 1 - policy server
docker run --rm --gpus all --net host \
  -e HF_HOME=/root/.cache/huggingface \
  -v ~/.cache/huggingface:/root/.cache/huggingface \
  --entrypoint bash j3soon/runai-cosmos:3 \
  -c 'python -u -m cosmos_framework.scripts.action_policy_server_robolab --port 8000'

# Terminal 2 - RoboLab client
docker run --rm --gpus all --net host \
  -v "$(pwd)/artifacts/robolab/out:/workspace/robolab/output" \
  --entrypoint /workspace/isaaclab/_isaac_sim/python.sh \
  j3soon/runai-robolab:0.3.0 \
  -u policies/cosmos3/run.py --task BananaInBowlTask --headless --num-envs 1
```

The checkpoint is about 30GB and is **not** gated, so no `HF_TOKEN` is required. Wait for `Server accessible at: ws://...:8000/` before starting the client; `curl http://127.0.0.1:8000/healthz` returns 200 once ready. For the smaller sibling, add `--checkpoint-path nvidia/Cosmos3-Edge-Policy-DROID --format-prompt-as-json True` to the server command.

### Verified locally: GR00T N1.7

The GR00T client speaks ZMQ on port 5555 against [Isaac-GR00T](https://github.com/NVIDIA/Isaac-GR00T)'s `run_gr00t_server.py` with the `nvidia/GR00T-N1.7-DROID` checkpoint and the `OXE_DROID_RELATIVE_EEF_RELATIVE_JOINT` embodiment tag. This repository does not publish an N1.7 image yet, so build one from the upstream `docker/Dockerfile` at a pinned commit. Two environment variables are required when running that image:

- `PYTHONUNBUFFERED=1`, or the server's readiness banner stays buffered and a healthy server looks hung at `Loading checkpoint shards`.
- `PYTHONPATH=/workspace` with the upstream source mounted there, because the image runs `uv sync --no-install-project` and therefore does not install the `gr00t` package itself.

```sh
/workspace/isaaclab/_isaac_sim/python.sh -u policies/gr00t/run.py \
    --headless --task BananaInBowlTask --num-envs 1 \
    --remote-host 127.0.0.1 --remote-port 5555 --open-loop-horizon 8
```

The checkpoint itself is not gated, but it loads the gated [`nvidia/Cosmos-Reason2-2B`](https://huggingface.co/nvidia/Cosmos-Reason2-2B) backbone, so the server needs `HF_TOKEN` (401 without it). Accept the license first, then pass the token as an environment variable.

### Benchmarking notes

For measured throughput per backend, the variance caveat, and the resource footprint, see the
[performance guide](./performance.md).

Two rules when measuring here. Read per-run figures from the `timing` block RoboLab writes into
`episode_results.jsonl` rather than from log output, since the first inference includes
compilation. And quote success rates from several episodes, never one: the Cosmos 3 policy server
runs with `deterministic_seed=False`, so a single episode cannot distinguish a real difference from
variance. `--num-envs 4` costs little more wall-clock than `--num-envs 1`.

### On Run:ai

`--net host` co-location does not translate directly to two Run:ai workloads, which would need a Service for pod-to-pod traffic. The simpler arrangement is one workload per GPU running both processes, which requires a combined image since the server and client images differ. Check the pair's combined VRAM against the target node before assuming they co-locate: with a large policy server such as Cosmos 3 they can exceed a `prod` L40's 46GB.

## Run Locally

To smoke-test the image outside Run:ai, on a machine with an NVIDIA RTX GPU and the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html). Write outputs under this repository's gitignored `artifacts/` directory:

```sh
mkdir -p artifacts/robolab
docker run --rm --gpus all --network=host \
  --entrypoint /workspace/isaaclab/_isaac_sim/python.sh \
  -v "$(pwd)/artifacts/robolab:/workspace/robolab/output" \
  j3soon/runai-robolab:0.3.0 \
  -u examples/run_empty.py --headless --task BananaInBowlTask
```

This runs one 50-step episode with random actions and prints an experiment summary table. It writes `artifacts/robolab/run_empty_env/episode_results.jsonl` plus `run_empty_env/BananaInBowlTask/{env_cfg.json,log_0_env0.json}`, and exercises environment creation, asset loading, stepping, and subtask success detection without needing a policy server. Success is `False` here by design, since the actions are random.

Notes:

- The container runs as root, so outputs are root-owned on the host. Reclaim them with `sudo chown -R "$(id -u):$(id -g)" artifacts/robolab`.
- Startup takes a few minutes before the first step: Omniverse compiles its shader caches inside the container, and `--rm` discards them. Mount the standard Isaac Sim cache directories (`/isaac-sim/kit/cache`, `/root/.cache/ov`, `/root/.cache/nvidia/GLCache`, `/root/.nv/ComputeCache`) to reuse them across runs. 
- `--network=host` is only needed when connecting to a policy server. Drop it for `run_empty.py`.
- To capture video of a run, use RoboLab's own recorder rather than a screen grabber. `examples/run_gripper_toggle.py --headless` writes a sensor MP4 (third-person and wrist cameras side by side) and a viewport MP4 per environment under `output/run_gripper_toggle/<task>/`, both at 15fps. Isaac Sim presents its viewport through a Vulkan swapchain, so `ffmpeg -f x11grab` records solid black even when the GUI window is mapped and rendering normally; capture through the compositor if you need an actual screen recording.
- Rendering artefacts can linger for a few frames after a scene reload. This is an upstream Isaac Lab/RTX behavior, not a RoboLab failure.
- Clean up with `docker rmi j3soon/runai-robolab:0.3.0`.

### Inherited upstream caveats

Both are inherited from upstream's own install, not introduced by this image:

- RoboLab's `tyro` dependency upgrades `docstring-parser` from 0.16 to 0.18, which pip reports as incompatible with the base image's `nvidia-srl-base` package. That package backs the Isaac Sim USD-to-URDF converter tooling, which RoboLab evaluation does not use; the benchmark run is unaffected.
- On a driver newer than Isaac Sim 5.0 expects, Warp logs `Failed to get driver entry point 'cuDeviceGetUuid'` and `CUDA error 36` at startup. Observed on driver 580.173.02 with an RTX PRO 6000 Blackwell, where the run still completed on GPU at full speed. Treat it as a warning, not a failure, but confirm your own runs reach the step loop rather than assuming.

## Extending The Benchmark

Tasks are not tied to a specific robot embodiment, so any Isaac Lab-compatible robot can be plugged in. Upstream documents [objects](https://github.com/NVlabs/RoboLab/blob/v0.3.0/docs/objects.md), [scenes](https://github.com/NVlabs/RoboLab/blob/v0.3.0/docs/scene.md), [tasks](https://github.com/NVlabs/RoboLab/blob/v0.3.0/docs/task.md), and [environment registration](https://github.com/NVlabs/RoboLab/blob/v0.3.0/docs/environment_registration.md) for authoring new content. Keep custom task and scene code on `/mnt/nfs/<YOUR_USERNAME>` so it survives the workload, and note that new USD assets are not covered by the baked-in asset library.
