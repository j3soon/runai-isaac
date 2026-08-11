# Isaac Lab Arena

This page is part of the sample applications guide. Follow [README](../../README.md) first and stop interactive workloads when finished.

[Isaac Lab Arena](https://isaac-sim.github.io/IsaacLab-Arena/main/index.html) is an Isaac Lab extension for composable task curation and large-scale robot policy evaluation. Environments are assembled from independent Scene, Embodiment, and Task building blocks, so the same policy can be evaluated across many robot/scene/task combinations without writing a configuration per combination.

Arena is an early release: upstream marks the `0.2.x` APIs as unstable and its features as incomplete.

1. (Optional) Create a docker image for Isaac Lab Arena following the [installation guide](https://isaac-sim.github.io/IsaacLab-Arena/main/pages/quickstart/installation.html):

   ```sh
   docker build -t j3soon/runai-isaac-lab-arena:0.2.1 -f docker/isaac-lab-arena/Dockerfile_0_2_1 .
   docker push j3soon/runai-isaac-lab-arena:0.2.1
   ```

   Upstream publishes no Git tags, so [`Dockerfile_0_2_1`](./Dockerfile_0_2_1) pins the `release/0.2.1` head commit (`8b4a3a4`) together with the `submodules/IsaacLab` and `submodules/Isaac-GR00T` commits that Arena pins at that revision. It builds on `nvcr.io/nvidia/isaac-sim:6.0.0-dev2`, the base image upstream selects for this release line.

   The upstream Dockerfile builds from a local checkout with initialized submodules, which is unavailable when building from this repository root, so this is a self-contained variant that clones those repositories at their pinned commits during the build. It also drops the upstream entrypoint, which requires the `DOCKER_RUN_USER_ID` / `DOCKER_RUN_GROUP_ID` variables that `docker/run_docker.sh` supplies and Run:ai does not, and drops the optional `INSTALL_GROOT=true` GR00T runtime (CUDA 12.8 + flash-attn), matching the upstream default. The lightweight GR00T remote policy client is still installed, so GR00T policies can be evaluated against a policy server running elsewhere.

   > This step is optional since we provide pre-built docker images on Docker Hub.

   > Environment command:
   >
   > ```
   > /run.sh "/isaac-sim/python.sh -u /workspace/isaaclab_arena/evaluation/policy_runner.py --policy_type zero_action --num_steps 20 cube_goal_pose"
   > ```
   >
   > The `-u` flag is required for correct logging by setting unbuffered mode. Isaac Lab 3.x runs headless by default when no `--visualizer` / `--viz` backend is requested, so no `--headless` flag is needed; that flag is deprecated in this release.

2. Create the Run:ai environment and workload.

   The Run:ai setup is identical to [Isaac Lab](../isaac-lab/README.md) — follow its environment
   and workspace steps, substituting the image and command for this application:

   - Image URL: `j3soon/runai-isaac-lab-arena:0.2.1`
   - Command: the environment command above, with `Arguments` left empty
   - Security: set UID/GID `From the image`

3. Wait for the workload to finish. Inspect the logs and delete the workload when done.

   Startup downloads Isaac Sim assets and compiles shaders before the rollout begins. Look for `[isaaclab-arena] AppLauncher initialization complete` in the logs to confirm the simulator came up, then `Starting rollout`. Enabling cameras on a cold shader cache adds minutes; see the [performance guide](./performance.md).

   The `zero_action` policy sends no actions, so it reports `{'success_rate': 0.0, 'object_moved_rate': nan, 'num_episodes': 0}` over 20 steps. That is the expected result for this check: it verifies the simulator, environment, and policy plumbing, not task performance. Use a real policy and `--num_episodes` to get meaningful metrics.

## Running Evaluations

> Below is usage guide specific for this image.

The image installs Arena as an editable package at `/workspace`, with Isaac Lab under `/workspace/submodules/IsaacLab` and Isaac Sim at `/isaac-sim`. Run scripts with the Isaac Sim interpreter (`/isaac-sim/python.sh`); inside an interactive shell, the `python`, `pip3`, and `pytest` aliases already point at it.

Roll out a single policy in a single environment with [`policy_runner.py`](https://github.com/isaac-sim/IsaacLab-Arena/blob/release/0.2.1/isaaclab_arena/evaluation/policy_runner.py). The environment name is a positional argument:

```sh
/isaac-sim/python.sh -u /workspace/isaaclab_arena/evaluation/policy_runner.py \
    --policy_type zero_action --num_steps 20 cube_goal_pose
```

Useful flags: `--num_envs` for parallel environments, `--num_episodes` instead of `--num_steps`, `--seed`, and `--presets physx|newton` for the physics backend.

To record an mp4 of the rollout, pass `--video` (writing to `--video_dir`, default `/eval/videos`) **together with both `--enable_cameras` and `--viz kit`**. Two separate failure modes make this easy to get wrong:

- Without `--enable_cameras`, the render extensions are not loaded and the rollout aborts on the first step with `ModuleNotFoundError: No module named 'omni.replicator'`.
- With `--enable_cameras` but no visualizer, the run **succeeds and writes a valid mp4 that contains nothing** — an all-black first frame followed by a uniform light-gray background, with no scene geometry. Isaac Lab 3.x only populates a viewport when a `--visualizer` / `--viz` backend is active, and `env.render()` captures that viewport. Check the file size: a 20-frame 720p recording of a real scene is hundreds of KB, not ~3KB.

Recording forces a full render per step, so it is much slower than a headless evaluation. Use it for spot checks, not for large evaluation sweeps.

The available example environments are registered in [`isaaclab_arena_environments/cli.py`](https://github.com/isaac-sim/IsaacLab-Arena/blob/release/0.2.1/isaaclab_arena_environments/cli.py) and include `cube_goal_pose`, `lift_object`, `press_button`, `kitchen_pick_and_place`, `franka_put_and_close_door`, and several GR1 and Galileo G1 tasks.

Run a batch of evaluation jobs from a config file with [`eval_runner.py`](https://github.com/isaac-sim/IsaacLab-Arena/blob/release/0.2.1/isaaclab_arena/evaluation/eval_runner.py):

```sh
/isaac-sim/python.sh -u /workspace/isaaclab_arena/evaluation/eval_runner.py \
    --eval_jobs_config isaaclab_arena_environments/eval_jobs_configs/zero_action_jobs_config.json
```

The config path is relative to the image's working directory, `/workspace`.

For multi-GPU evaluation, launch one process per GPU with `torchrun` and pass `--distributed`; Arena assigns each process a device from `LOCAL_RANK`:

```sh
/isaac-sim/python.sh -u -m torch.distributed.run --nnodes=1 --nproc_per_node=2 \
    /workspace/isaaclab_arena/evaluation/policy_runner.py \
    --policy_type zero_action --num_steps 20 --distributed cube_goal_pose
```

For multi-node evaluation, follow the same Run:ai **Distributed** PyTorch **Training** setup described in the [Isaac Lab guide](../isaac-lab/README.md#distributed-training-on-runai) and leave the launcher options unset so `torchrun` consumes the operator-provided rendezvous settings.

### Train An RSL-RL Policy, Then Evaluate It

`--policy_type rsl_rl` needs a checkpoint plus the `params/agent.yaml` written beside it. Either
download a pre-trained one or produce it with Isaac Lab's `train.py`.

The pre-trained checkpoint is public and needs no token:

```sh
hf download nvidia/Arena-Franka-Lift-Object-RL-Task --local-dir /models/lift_object_checkpoint
```

It ships `model_1999.pt` and `model_1000.pt` alongside `params/agent.yaml`, which is the layout the
policy expects. `nvidia/Arena-Dexsuite-Lift-RL-Newton-Task` covers the DexSuite task. Both were
absent when this guide was first written and were published on 2026-08-10 in response to
[IsaacLab-Arena#904](https://github.com/isaac-sim/IsaacLab-Arena/issues/904).

Training uses Isaac Lab's RSL-RL script with an Arena callback that registers the Arena environment
under the `--task` name. Mount a persistent directory at `/workspace/logs`, since checkpoints are
written there and are otherwise lost with the container:

```sh
/isaac-sim/python.sh -u /workspace/submodules/IsaacLab/scripts/reinforcement_learning/rsl_rl/train.py \
    --external_callback isaaclab_arena.environments.isaaclab_interop.environment_registration_callback \
    --task lift_object --rl_training_mode --num_envs 4096 --max_iterations 2000
```

Checkpoints land in `logs/rsl_rl/generic_experiment/<timestamp>/` as `model_<iteration>.pt`, saved
every `agent.save_interval` iterations (default 200) and again at the end. That interval, not where
you stop, decides what survives an interrupted run. See the [performance guide](./performance.md)
for throughput and the reward curve.

Evaluate the checkpoint, recording video. Policy arguments must come **before** the environment name:

```sh
/isaac-sim/python.sh -u /workspace/isaaclab_arena/evaluation/policy_runner.py \
    --viz kit --enable_cameras --video \
    --policy_type rsl_rl \
    --checkpoint_path /workspace/logs/rsl_rl/generic_experiment/<timestamp>/model_1999.pt \
    --num_episodes 2 \
    lift_object
```

Unlike `zero_action`, this reports a real `success_rate`; see the
[performance guide](./performance.md) for what a partially trained checkpoint scores.

### Evaluating A GR00T Policy

Arena 0.2.1 targets GR00T **N1.6**, not N1.7: its configs under `isaaclab_arena_gr00t/policy/config/` use `embodiment_tag: GR1` and expect a finetuned checkpoint on disk (for example `/models/isaaclab_arena/static_manipulation_tutorial/checkpoint-20000`). NVIDIA publishes matching Arena-tuned checkpoints — `nvidia/GN16-Tuned-Arena-GR1-Manipulation`, `nvidia/GN1.6-Tuned-Arena-GR1-PlaceItemCloseDoor-Task`, and `nvidia/GN1x-Tuned-Arena-G1-Static-PickNPlace` are public and need no token.

Download the checkpoint. Only inference files are needed — the full repository is 50.6GB, mostly
training state:

```sh
hf download nvidia/GN1x-Tuned-Arena-GR1-Manipulation --revision gn1_6 \
  --local-dir /models/isaaclab_arena/static_manipulation_tutorial/checkpoint-20000 \
  --exclude "global_step20000/*" "optimizer.pt"
```

That path must match `model_path` in the policy YAML. Then either:

- **Local (verified).** `gr00t_jobs_config.json` uses `Gr00tClosedloopPolicy`, which loads the checkpoint in-process. This image ships the `gr00t` package without `flash_attn`, `peft`, `diffusers`, or `accelerate`; upstream's `docker/setup/install_gr00t_deps.sh` adds them under `/opt/groot_deps`. Run with `PYTHONPATH=$PYTHONPATH:/opt/groot_deps`:

  ```sh
  /isaac-sim/python.sh -u /workspace/isaaclab_arena/evaluation/policy_runner.py \
      --policy_type isaaclab_arena_gr00t.policy.gr00t_closedloop_policy.Gr00tClosedloopPolicy \
      --policy_config_yaml_path isaaclab_arena_gr00t/policy/config/gr1_manip_gr00t_closedloop_config.yaml \
      --policy_device cuda:0 --enable_cameras --num_steps 60 \
      gr1_open_microwave --object cracker_box --embodiment gr1_joint
  ```

  Two things this fails on otherwise. **`--enable_cameras` is mandatory** — GR00T is a vision policy, and without it the checkpoint loads, the rollout starts, and the first step dies with `camera_obs is not in observation`. And **remove DeepSpeed** (`rm -rf /opt/groot_deps/deepspeed*`) unless you also ran upstream's `install_cuda.sh`: `transformers` auto-detects it and it aborts the import with `CUDA_HOME does not exist, unable to compile CUDA op(s)`. DeepSpeed is only needed for training.

  flash-attn comes from a prebuilt `cu128torch2.10-cp312` wheel matching this image's torch, and it runs on Blackwell — `sm_120` is in `torch.cuda.get_arch_list()` and a bf16 `flash_attn_func` forward returns finite output on an RTX PRO 6000 (cc 12.0).

- **Remote (not yet exercised).** Serve the policy from a separate workload built on the [Isaac GR00T N1.6 image](../isaac-gr00t-n1.6/README.md) and point Arena's client at it with `--policy_type gr00t_remote_closedloop --remote_host <host> --remote_port 5555`. This image already ships the client side (`pyzmq`, `msgpack`), so it needs no rebuild.

## Run Locally

To smoke-test the image outside Run:ai, on a machine with an NVIDIA GPU and the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html). Isaac Sim caches shaders and downloaded assets, so mount those caches to keep later startups fast, and write evaluation outputs under this repository's gitignored `artifacts/` directory:

```sh
mkdir -p ~/docker/isaac-sim/{cache/kit,cache/ov,cache/pip,cache/glcache,cache/computecache,logs,data,documents} \
         artifacts/isaac-lab-arena/eval
docker run --rm --gpus all --ipc=host \
  -v ~/docker/isaac-sim/cache/kit:/isaac-sim/kit/cache:rw \
  -v ~/docker/isaac-sim/cache/ov:/root/.cache/ov:rw \
  -v ~/docker/isaac-sim/cache/pip:/root/.cache/pip:rw \
  -v ~/docker/isaac-sim/cache/glcache:/root/.cache/nvidia/GLCache:rw \
  -v ~/docker/isaac-sim/cache/computecache:/root/.nv/ComputeCache:rw \
  -v ~/docker/isaac-sim/logs:/root/.nvidia-omniverse/logs:rw \
  -v ~/docker/isaac-sim/data:/root/.local/share/ov/data:rw \
  -v ~/docker/isaac-sim/documents:/root/Documents:rw \
  -v "$(pwd)/artifacts/isaac-lab-arena/eval:/eval" \
  j3soon/runai-isaac-lab-arena:0.2.1 \
  /isaac-sim/python.sh -u /workspace/isaaclab_arena/evaluation/policy_runner.py \
      --policy_type zero_action --num_steps 60 --enable_cameras --video --viz kit cube_goal_pose
```

The recorded rollout is written to `artifacts/isaac-lab-arena/eval/videos/rl-video-step-0.mp4`, a 1280x720 h264 clip of the Franka arm and cube on the workbench. If that file is only a few KB, the render produced an empty viewport — see the `--viz kit` note above and the [performance guide](./performance.md) for expected sizes.

Notes:

- The container runs as root, so outputs are root-owned on the host. Reclaim them with `sudo chown -R "$(id -u):$(id -g)" artifacts/isaac-lab-arena`.
- `--ipc=host` gives the container the host's shared memory. If your security policy disallows it, raise `--shm-size` instead.
- Clean up with `docker rmi j3soon/runai-isaac-lab-arena:0.2.1` and by deleting `~/docker/isaac-sim`.

## Storage And Environment Variables

Container-local data is lost when the workload stops. Point the following at a persistent mount such as `/mnt/nfs/<YOUR_USERNAME>` instead of the container filesystem:

| Path or variable | Purpose |
| --- | --- |
| `/eval` | Default root for evaluation outputs and recorded videos (`--video_dir`). |
| `/datasets` | Conventional mount for datasets in the upstream container workflow. |
| `/models` | Conventional mount for policy checkpoints in the upstream container workflow. |
| `HF_HOME` | Cache directory for Hugging Face models and datasets. |
| `HF_TOKEN` | Hugging Face token for gated downloads. |

Keep any modified Arena or Isaac Lab code under `/mnt/nfs/<YOUR_USERNAME>` and run the workload from there, so results survive workload termination.

Arena downloads its default simulation assets from public Omniverse locations, so no credentials are needed for the example environments. If you extend Arena with assets on a private Nucleus server, follow the upstream [Omniverse authentication guide](https://isaac-sim.github.io/IsaacLab-Arena/main/pages/advanced/private_omniverse.html) and set `OMNI_USER` (the literal `$omni-api-token`) and `OMNI_PASS` on the workload.
