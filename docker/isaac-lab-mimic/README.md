# Isaac Lab Mimic and SkillGen

This page is part of the sample applications guide. Follow [README](../../README.md) first and stop interactive workloads when finished.

[Isaac Lab Mimic](https://isaac-sim.github.io/IsaacLab/main/source/overview/imitation-learning/teleop_imitation.html) turns a handful of teleoperated demonstrations into a large synthetic dataset by replaying annotated subtask segments against randomized scenes. [SkillGen](https://isaac-sim.github.io/IsaacLab/main/source/overview/imitation-learning/skillgen.html) extends the same pipeline with a cuRobo motion planner, so the transit motion between skills is planned and collision-aware instead of interpolated.

This image is the stock Isaac Lab container plus the pieces the upstream guides ask you to install by hand, so `--use_skillgen` works out of the box:

- **cuRobo**, built from source against the container's PyTorch. It is not bundled in the base image, even though Isaac Lab already ships the SkillGen planner that imports it.
- A **CUDA toolkit** matching that PyTorch build, because cuRobo compiles CUDA extensions and the base image has no `nvcc`.
- A one-line **Franka asset path fix**; see [Developer Notes](#developer-notes).

`robomimic`, `rerun-sdk`, and `pinocchio` are already in the base image, so no extra layer is needed for them.

| Isaac Lab | Isaac Sim | cuRobo | Image URL |
|-----------|-----------|--------|-----------|
| 3.0.0-beta2.patch1 | 6.0.1 | [`ebb7170`](https://github.com/NVlabs/curobo/commit/ebb71702f3f70e767f40fd8e050674af0288abe8) | j3soon/runai-isaac-lab-mimic:3.0.0-beta2.patch1 |

## Build (Optional)

> Skip this section if you want to use our pre-built docker images on Docker Hub.

```sh
docker build -t j3soon/runai-isaac-lab-mimic:3.0.0-beta2.patch1 -f docker/isaac-lab-mimic/Dockerfile_3_0_0_beta2_patch1 .
docker push j3soon/runai-isaac-lab-mimic:3.0.0-beta2.patch1
```

The cuRobo layer compiles for `TORCH_CUDA_ARCH_LIST="8.9;9.0;12.0+PTX"` by default, covering L40/L40S, H100, and RTX PRO 6000 Blackwell. Narrow it to the one architecture you need to cut build time:

```sh
docker build --build-arg TORCH_CUDA_ARCH_LIST="8.9" \
  -t j3soon/runai-isaac-lab-mimic:3.0.0-beta2.patch1 \
  -f docker/isaac-lab-mimic/Dockerfile_3_0_0_beta2_patch1 .
```

Pass `--build-arg MAX_JOBS=<n>` to bound the `nvcc` fan-out if the build host is memory-constrained; it defaults to 8.

A wrong architecture list only fails at run time, and importing `curobo` is not enough to catch it — the CUDA extensions load lazily, so `import curobo` succeeds even when no kernel matches the GPU. Solve something instead:

```sh
docker run --rm --gpus all --entrypoint bash j3soon/runai-isaac-lab-mimic:3.0.0-beta2.patch1 -lc '
/workspace/isaaclab/_isaac_sim/python.sh -c "
from curobo.types.base import TensorDeviceType
from curobo.types.math import Pose
from curobo.types.robot import RobotConfig
from curobo.util_file import get_robot_configs_path, join_path, load_yaml
from curobo.wrap.reacher.ik_solver import IKSolver, IKSolverConfig
tdt = TensorDeviceType()
cfg = RobotConfig.from_dict(load_yaml(join_path(get_robot_configs_path(), \"franka.yml\"))[\"robot_cfg\"], tdt)
ik = IKSolver(IKSolverConfig.load_from_robot_config(cfg, None, num_seeds=20, tensor_args=tdt))
fk = ik.fk(ik.sample_configs(5))
print(\"IK success:\", ik.solve_batch(Pose(fk.ee_position, fk.ee_quaternion)).success.flatten().tolist())
"'
```

It should print five `True` values.

## Datasets

Both workflows start from demonstrations recorded by hand. NVIDIA publishes ready-made copies, which is the fastest way to exercise the pipeline and the only practical route on a headless cluster:

```sh
mkdir -p datasets
BASE=https://omniverse-content-production.s3-us-west-2.amazonaws.com/Assets/Isaac/6.0/Isaac/IsaacLab/Mimic/franka_stack_datasets
# 10 teleoperated demos, Isaac-Stack-Cube-Franka-IK-Rel-v0
curl -fsSL -o datasets/dataset.hdf5 "$BASE/dataset.hdf5"
# 10 demos already carrying subtask start *and* termination signals, for SkillGen
curl -fsSL -o datasets/annotated_dataset_skillgen.hdf5 "$BASE/annotated_dataset_skillgen.hdf5"
```

> The upstream pages link these under `Assets/Isaac/5.0` and `Assets/Isaac/5.1`. The `6.0` copies used above are the same objects (identical size and S3 ETag), and `6.0` is the asset generation this image resolves against.

## Local

Mount a host directory for the datasets and reuse the Isaac Sim cache between runs; the first launch spends a few minutes populating shader and asset caches.

```sh
mkdir -p ~/docker/isaac-sim/cache/{ov,pip,glcache,computecache}

docker run --rm --gpus all \
  -e ACCEPT_EULA=Y -e PRIVACY_CONSENT=Y \
  --memory=24g --memory-swap=24g --shm-size=8g \
  -v ~/docker/isaac-sim/cache/ov:/root/.cache/ov:rw \
  -v ~/docker/isaac-sim/cache/pip:/root/.cache/pip:rw \
  -v ~/docker/isaac-sim/cache/glcache:/root/.cache/nvidia/GLCache:rw \
  -v ~/docker/isaac-sim/cache/computecache:/root/.nv/ComputeCache:rw \
  -v "$PWD/datasets:/datasets:rw" \
  j3soon/runai-isaac-lab-mimic:3.0.0-beta2.patch1 \
  /run.sh "<command>"
```

Mount the cache subdirectories individually rather than all of `/root/.cache`, which would mask the caches the image ships.

Each `<command>` below is a single `/run.sh` argument. Keep the memory cap on a workstation; Isaac Sim will otherwise grow into the host's RAM.

### Isaac Lab Mimic

Annotate the recorded demos. `--auto` derives subtask boundaries from the environment's `subtask_terms` observations, so no interaction is needed:

```sh
/workspace/isaaclab/isaaclab.sh -p -u scripts/imitation_learning/isaaclab_mimic/annotate_demos.py --device cpu --task Isaac-Stack-Cube-Franka-IK-Rel-Mimic-v0 --auto --input_file /datasets/dataset.hdf5 --output_file /datasets/annotated_dataset.hdf5
```

Generate a small dataset to confirm the setup, then scale up:

```sh
# smoke test
/workspace/isaaclab/isaaclab.sh -p -u scripts/imitation_learning/isaaclab_mimic/generate_dataset.py --device cpu --num_envs 10 --generation_num_trials 10 --input_file /datasets/annotated_dataset.hdf5 --output_file /datasets/generated_dataset_small.hdf5
# full dataset
/workspace/isaaclab/isaaclab.sh -p -u scripts/imitation_learning/isaaclab_mimic/generate_dataset.py --device cpu --num_envs 10 --generation_num_trials 1000 --input_file /datasets/annotated_dataset.hdf5 --output_file /datasets/generated_dataset.hdf5
```

> The upstream guides pass `--headless` to these commands. Isaac Lab 3.0 is headless by default and prints `The '--headless' CLI argument is deprecated`; the commands above omit it. Use `--viz kit` to opt into a window instead.

### SkillGen

SkillGen needs both subtask *start* and *termination* signals and has no `--auto` mode, so its dataset cannot be annotated unattended — that is why the section above downloads `annotated_dataset_skillgen.hdf5`. Add `--use_skillgen` and pass `--task` explicitly:

```sh
# cube stacking
/workspace/isaaclab/isaaclab.sh -p -u scripts/imitation_learning/isaaclab_mimic/generate_dataset.py --device cpu --num_envs 1 --generation_num_trials 10 --input_file /datasets/annotated_dataset_skillgen.hdf5 --output_file /datasets/generated_dataset_small_skillgen_cube_stack.hdf5 --task Isaac-Stack-Cube-Franka-IK-Rel-Skillgen-v0 --use_skillgen
# adaptive stacking inside a narrow bin
/workspace/isaaclab/isaaclab.sh -p -u scripts/imitation_learning/isaaclab_mimic/generate_dataset.py --device cpu --num_envs 1 --generation_num_trials 10 --input_file /datasets/annotated_dataset_skillgen.hdf5 --output_file /datasets/generated_dataset_small_skillgen_bin_cube_stack.hdf5 --task Isaac-Stack-Cube-Bin-Franka-IK-Rel-Mimic-v0 --use_skillgen
```

Raise `--generation_num_trials` to 1000 for a full dataset. Upstream reports 90–120 minutes for the cube-stacking task and about 220 minutes for the bin task at that scale on an RTX 6000 Ada, and recommends keeping `--num_envs` between 1 and 5 (about 9.5 GB VRAM at 1 env, about 22 GB at 5).

To record and annotate your own SkillGen demonstrations, use `--task Isaac-Stack-Cube-Franka-IK-Rel-Skillgen-v0` with `scripts/tools/record_demos.py`, then `annotate_demos.py --annotate_subtask_start_signals` *without* `--auto`, marking each boundary by hand (`N` play, `B` pause, `S` mark, `Q` skip). Both need an interactive display — see [Teleoperation](#teleoperation).

### Training and evaluation

`robomimic` is preinstalled. Point `--log_dir` at the mounted directory so checkpoints survive the container:

```sh
/workspace/isaaclab/isaaclab.sh -p -u scripts/imitation_learning/robomimic/train.py --task Isaac-Stack-Cube-Franka-IK-Rel-v0 --algo bc --dataset /datasets/generated_dataset.hdf5 --log_dir /datasets/robomimic
/workspace/isaaclab/isaaclab.sh -p -u scripts/imitation_learning/robomimic/play.py --device cpu --task Isaac-Stack-Cube-Franka-IK-Rel-v0 --num_rollouts 50 --checkpoint /datasets/robomimic/<task>/<experiment>/<timestamp>/models/model_epoch_<n>.pth
```

`train.py` accepts `--epochs` to override the 2000-epoch default from the JSON config, which is useful for a quick end-to-end check. Swap the task for `Isaac-Stack-Cube-Franka-IK-Rel-Skillgen-v0` or `Isaac-Stack-Cube-Bin-Franka-IK-Rel-Mimic-v0` when training on SkillGen data. Upstream reports 40–85% policy success from 1000 generated demos at the default 2000 epochs, and recommends evaluating several checkpoints past epoch 1000 rather than only the last.

## Teleoperation

> Partially verified. The GUI path below was confirmed — the Kit window maps on the host display and the environment builds. Recording a demonstration end to end needs a human at the keyboard and was not machine-verified, so treat the interaction details as upstream's rather than as measured here.

Recording your own demonstrations needs an interactive display, and in Isaac Lab 3.0 you must ask for one explicitly — `record_demos.py` imports `omni.ui` at module scope and dies with `ModuleNotFoundError: No module named 'omni.ui'` under the default headless app. Add `--viz kit`:

```sh
xhost +local:                     # allow the container to reach your X display
docker run --rm --gpus all \
  -e ACCEPT_EULA=Y -e PRIVACY_CONSENT=Y -e DISPLAY=$DISPLAY \
  --memory=24g --memory-swap=24g --shm-size=8g \
  -v /tmp/.X11-unix:/tmp/.X11-unix:rw \
  -v ~/docker/isaac-sim/cache/ov:/root/.cache/ov:rw \
  -v ~/docker/isaac-sim/cache/computecache:/root/.nv/ComputeCache:rw \
  -v "$PWD/datasets:/datasets:rw" \
  j3soon/runai-isaac-lab-mimic:3.0.0-beta2.patch1 \
  /run.sh "/workspace/isaaclab/isaaclab.sh -p -u scripts/tools/record_demos.py --task Isaac-Stack-Cube-Franka-IK-Rel-v0 --device cpu --viz kit --teleop_device keyboard --dataset_file /datasets/dataset_teleop.hdf5 --num_demos 10"
xhost -local:                     # revoke when finished
```

`R` resets the current recording instance. Replay what you recorded with `scripts/tools/replay_demos.py`, then feed it to `annotate_demos.py` as above.

In Isaac Lab 3.0 `--teleop_device` is the *legacy* path; omitting it selects the newer IsaacTeleop stack driven by `env_cfg.teleop_devices`. A SpaceMouse additionally needs device permissions on the host (`sudo chmod 666 /dev/hidraw<#>`) and the device passed into the container.

**On Run:ai this workflow has no supported path.** It needs a live display and a human at the keyboard, and no Isaac Lab image in this repository offers a GUI at 3.0 — the VNC/noVNC `-ex` images stop at 2.3.2, and `j3soon/runai-isaac-lab-ex:3.0.0-beta2.patch1-ros2-jazzy` is a different, self-contained image that does not carry cuRobo. Record demonstrations on a workstation, or use NVIDIA's published datasets, and run only the batch stages on the cluster.

## Run:ai

Refer to [Isaac Lab Headless Workspace](../isaac-lab/README.md) for environment and workload setup; only the image URL changes. Every stage except teleoperation is a finite batch command, so use a **training** workload rather than a workspace, and keep datasets and checkpoints on NFS:

```sh
BASE=https://omniverse-content-production.s3-us-west-2.amazonaws.com/Assets/Isaac/6.0/Isaac/IsaacLab/Mimic/franka_stack_datasets
D=/mnt/nfs/<YOUR_USERNAME>/isaac-lab-mimic/datasets

runai training standard submit <YOUR_USERNAME>-mimic-generate \
  --project <YOUR_PROJECT> --node-pools prod \
  --image j3soon/runai-isaac-lab-mimic:3.0.0-beta2.patch1 --image-pull-policy Always \
  --gpu-devices-request 1 --large-shm \
  --backoff-limit 0 --restart-policy Never \
  --nfs "server=<NFS_SERVER>,path=<NFS_EXPORT>,mountpath=/mnt/nfs,readwrite" \
  --command -- /run.sh "mountpoint -q /mnt/nfs" "mkdir -p $D" \
    "curl -fsSL -o $D/annotated_dataset_skillgen.hdf5 $BASE/annotated_dataset_skillgen.hdf5" \
    "/workspace/isaaclab/isaaclab.sh -p -u scripts/imitation_learning/isaaclab_mimic/generate_dataset.py --device cpu --num_envs 1 --generation_num_trials 10 --input_file $D/annotated_dataset_skillgen.hdf5 --output_file $D/generated_dataset_small_skillgen_cube_stack.hdf5 --task Isaac-Stack-Cube-Franka-IK-Rel-Skillgen-v0 --use_skillgen"
```

Notes:

- `/run.sh` takes each stage as a **separate argument** and word-splits without a shell, so a multi-stage pipeline chains cleanly without quoting tricks. Keep `mountpoint -q /mnt/nfs` first as a mount guard.
- The cluster can reach the Omniverse asset server directly, so downloading the datasets inside the pod is simpler than uploading them.
- `--device cpu` keeps physics stable during generation, as upstream recommends; the GPU is still used for rendering and for cuRobo.
- The default `TORCH_CUDA_ARCH_LIST` includes `8.9`, which covers the L40 nodes in the `prod` pool.

## Developer Notes

Measured on an RTX PRO 6000 Blackwell (97 GB, sm_120, driver 580.173.02), Isaac Lab 3.0.0-beta2.patch1, `--device cpu`, containers capped at 24 GB RAM. Wall clock includes Isaac Sim startup with a warm cache.

| Stage | Arguments | Result | Wall clock |
|-------|-----------|--------|------------|
| `annotate_demos.py --auto` | 10 recorded demos | 10/10 episodes exported | — |
| `generate_dataset.py` (Mimic) | `--num_envs 10 --generation_num_trials 10` | 10/30 attempts (33.3%) | 36 s |
| `generate_dataset.py --use_skillgen` | cube stacking, `--num_envs 1` | 10/25 attempts (40.0%) | 212 s |
| `generate_dataset.py --use_skillgen` | bin stacking, `--num_envs 1` | 10/32 attempts (31.2%) | 380 s |
| `robomimic/train.py` | `--algo bc --epochs 50` on 10 demos | `model_epoch_50.pth` | 165 s |
| `robomimic/play.py` | 5 rollouts on that checkpoint | 0/5 success | 97 s |

The 0/5 evaluation is expected: 10 generated demos and 50 epochs is a plumbing check, not a training run. Upstream's 40–85% figures assume ~1000 demos and 2000 epochs.

Other things worth knowing:

- **`generate_dataset.py` writes a second `<output>_failed.hdf5`** holding the unsuccessful attempts. Both files are opened for the whole run, so do not read them until the process exits.
- **The base image entrypoint swallows the command.** `nvcr.io/nvidia/isaac-lab` sets `ENTRYPOINT ["/isaac-sim/runheadless.sh"]`, so a local `docker run <image> /run.sh "..."` appends the whole pipeline to the Kit command line and silently starts the Isaac Sim streaming app instead, idling until killed with no error. This image clears the entrypoint. Run:ai is unaffected because its `--command` overrides the entrypoint, which is why `docker/isaac-lab/` never hit this.
- **The Franka asset moved in the 6.0 asset generation.** Isaac Lab 3.0.0-beta2.patch1 resolves against `Assets/Isaac/6.0`, but the source still points at `Robots/FrankaEmika/panda_instanceable.usd`, which now lives under `Robots/FrankaEmika/Legacy/`. Without a fix, every environment spawning the Franka from that path — including all of the Mimic and SkillGen stacking tasks — aborts with `FileNotFoundError: USD file not found`. Two non-test files carry it, `isaaclab_assets/robots/franka.py` and `isaaclab_tasks/direct/franka_cabinet/franka_cabinet_env_cfg.py`, so the Dockerfile rewrites every reference under `source/` rather than just the first. The moved file is byte-identical to the 5.1 asset (same 8038-byte size and S3 ETag). Upstream `main` still carries the old path, so re-check on the next release.
- **SkillGen on L40 matches the workstation result.** The Run:ai command above was run as written on an L40 node (`--num_envs 1`, 10 trials): 10/22 attempts (45.5%) in 614 s wall clock, of which 3m26s was the first pull of the 18.9 GB image. A separate workload, after the generator pod exited, read the output off NFS and found 10 episodes under `Isaac-Stack-Cube-Franka-IK-Rel-Skillgen-v0` with a first-episode length of 465 steps — identical to the local run. This is the check that matters for the `8.9` entry in `TORCH_CUDA_ARCH_LIST`: cuRobo's kernels are compiled at build time, so a missing architecture would surface only here.
- **Do not inline a `python -c` one-liner in the workload command.** `/run.sh` word-splits without a shell, so the snippet arrives mangled and the pod fails with `SyntaxError`. `/run.sh --shell '...'` does not save you either — quotes and `\n` escapes are flattened by the CLI before they reach the container. Stage the script instead: `base64 -w0` it locally and decode it in the pod.
- **cuRobo must be compiled for the GPU you will run on.** The install is otherwise unremarkable, but it needs `nvcc` matching the container's PyTorch CUDA version, and the base image ships none.
- **`--headless` is deprecated** in Isaac Lab 3.0. Omitting it is equivalent: the same generation command produced 10/30 (33.3%) in 36 s with the flag and 37 s without.
