# Sim-to-Real SO-101 Workshop

This page is part of the sample applications guide. Follow [README](../../README.md) first and stop interactive workloads when finished.

(Optional) Create a docker image for the [Sim-to-Real SO-101 Workshop](https://github.com/isaac-sim/Sim-to-Real-SO-101-Workshop), an Isaac Lab task package for the [SO-101](https://github.com/TheRobotStudio/SO-ARM100) arm that accompanies NVIDIA's [sim-to-real learning content](https://docs.nvidia.com/learning/physical-ai/sim-to-real-so-101/latest/index.html). It provides the vial-to-rack manipulation task with domain randomization, LeRobot dataset recording, and closed-loop policy evaluation against a remote inference server.

`docker/sim-to-real-so101-workshop/Dockerfile` is a self-contained local variant that clones the upstream repo at a pinned commit during the build, since the upstream Dockerfile copies its own working tree and bind-mounts `source/` at run time. It uses the `nvcr.io/nvidia/isaac-lab:2.3.2` base image, matching upstream, and bakes in the Git LFS assets (USD scenes, 24 HDRI environment maps, vial textures) so no asset download is needed at runtime.

Only upstream's **sim/teleop** container is covered. Upstream's `docker/real/` images drive a physical SO-101 over `/dev/ttyACM*` with per-arm calibration and USB cameras, none of which exist on a Run:ai node; build those locally from upstream if you have the hardware.

```sh
docker build -f docker/sim-to-real-so101-workshop/Dockerfile . -t j3soon/runai-sim-to-real-so101-workshop:latest
```

> Environment command:

> ```
> /run.sh "/workspace/isaaclab/_isaac_sim/python.sh -u -m sim_to_real_so101.scripts.list_envs"
> ```
>
> The `-u` flag is required for correct logging by setting unbuffered mode. The package is installed into the Isaac Sim Python environment, so use `python.sh` rather than a system `python`, and `python.sh -m pip install ...` when adding packages.

## Tasks

| Task ID | Purpose |
| --- | --- |
| `Lerobot-So101-Teleop-Base` | Teleop debug |
| `Lerobot-So101-Teleop-Task` | Lightbox and cameras, non-task debug |
| `Lerobot-So101-Teleop-Vials-To-Rack` | Main task, no domain randomization |
| `Lerobot-So101-Teleop-Vials-To-Rack-DR` | Main task with domain randomization |
| `Lerobot-So101-Teleop-Vials-To-Rack-Eval` | Evaluation, fixed orange robot, no lighting/mat DR |
| `Lerobot-So101-Teleop-Vials-To-Rack-DR-Eval` | Evaluation with full domain randomization |

The upstream `entrypoint.sh` appends `docker/utils.sh` to `.bashrc`, which puts the console scripts (`list_envs`, `zero_agent`, `random_agent`, `lerobot_agent`, `lerobot_eval`, `lerobot_push_dataset`) on `PATH` in an interactive shell. Call them through `python.sh -m sim_to_real_so101.scripts.<name>` in a non-interactive workload command, where `.bashrc` is not sourced.

## What Runs On Run:ai

- **Works**: headless rollout (`zero_agent`, `random_agent`), closed-loop evaluation (`lerobot_eval`), and dataset replay/push.
- **Does not work**: teleoperation (`lerobot_agent`) needs a physical leader arm on a serial port, and the real-robot inference container needs USB cameras. Record datasets on a workstation with the hardware attached.

Always pass `--headless`.

### Verified locally

On an NVIDIA RTX PRO 6000 Blackwell (97GB, driver 580.173.02, `sm_120`), image built at 29.6GB:

```sh
# Task registration
docker run --rm --gpus all --ipc=host \
  --entrypoint /workspace/Sim-to-Real-SO-101-Workshop/docker/sim/entrypoint.sh \
  j3soon/runai-sim-to-real-so101-workshop:latest \
  /workspace/isaaclab/_isaac_sim/python.sh -u -m sim_to_real_so101.scripts.list_envs

# Headless scene load and physics stepping
docker run --rm --gpus all --ipc=host \
  --entrypoint /workspace/Sim-to-Real-SO-101-Workshop/docker/sim/entrypoint.sh \
  j3soon/runai-sim-to-real-so101-workshop:latest \
  /workspace/isaaclab/_isaac_sim/python.sh -u -m sim_to_real_so101.scripts.random_agent \
      --task Lerobot-So101-Teleop-Vials-To-Rack-Eval --num_envs 1 --headless
```

All six tasks register, the USD scene loads with no missing-asset errors, physics steps at a 1/120s step size, and the grasp/release subtask terms fire. `random_agent` loops until interrupted, so stop it once output appears.

`lerobot_eval` also runs headless, including its `KeyboardControl` construction — `omni.appwindow` binds fine without a display, so the interactive `R`-to-reset key costs nothing in a batch run. Verified against the stub policy server below:

```sh
docker run --rm --gpus all --ipc=host -v "$PWD/<path>/stub_policy_server.py:/stub.py:ro" \
  --entrypoint /workspace/Sim-to-Real-SO-101-Workshop/docker/sim/entrypoint.sh \
  j3soon/runai-sim-to-real-so101-workshop:latest \
  bash -c '/workspace/isaaclab/_isaac_sim/python.sh -u /stub.py --port 5555 & sleep 5;
           /workspace/isaaclab/_isaac_sim/python.sh -u -m sim_to_real_so101.scripts.lerobot_eval \
             --task Lerobot-So101-Teleop-Vials-To-Rack-Eval --headless --num_envs 1 \
             --num_episodes 2 --policy_host 127.0.0.1 --policy_port 5555 --action_horizon 16'
```

Observed: `Policy server connected`, two episodes stepped to the 450-step `time_out`, and a
final `Success Rate: 0/2 (0.0%)`, which is the correct result for a stub that holds position.
Cameras arrive as `ego` and `external_D455`, each `(1, 1, 480, 640, 3)`, and the server is
queried once per `--action_horizon` steps.

An episode is capped at 450 steps and took ~21s wall-clock on this GPU with a zero-latency
stub, so a 50-episode evaluation is roughly 18 minutes plus the policy's own inference time.
Budget `450 / action_horizon` server queries per episode when estimating that overhead.

> `tqdm` writes its progress bar to stderr and redraws with carriage returns, so a redirected
> log holds one very long line per episode. Filter with `grep -a` or pass `--num_episodes` and
> read only the final tally.

## Closed-Loop Policy Evaluation

`lerobot_eval` is a client: it steps the Isaac Lab env and queries a **remote policy server** over ZMQ, defaulting to `localhost:5555`. It does not bundle model weights.

```sh
/workspace/isaaclab/_isaac_sim/python.sh -u -m sim_to_real_so101.scripts.lerobot_eval \
    --task Lerobot-So101-Teleop-Vials-To-Rack-Eval --headless \
    --num_envs 1 --num_episodes 30 \
    --policy_host 127.0.0.1 --policy_port 5555 \
    --action_horizon 16 \
    --rename_map '{"external_D455": "front", "ego": "wrist"}' \
    --lang_instruction "Pick up the vial and place it in the yellow rack"
```

Those last two flags are **not optional** for the published GR00T finetunes, and the
defaults are wrong for them. See [upstream's evaluation
page](https://docs.nvidia.com/learning/physical-ai/sim-to-real-so-101/latest/11-sim-evaluation.html).

Success is a termination term (`vial_placed_on_rack_termination`), so an episode that ends in `terminated` counts as a success and one that ends in `time_out` counts as a failure. The script prints a running success rate and a final tally.

The server speaks the GR00T ZMQ protocol. Each observation is `{"video": {<camera>: img}, "state": {"single_arm": [5], "gripper": [1]}, "language": {"annotation.human.task_description": str}}`, with `(batch=1, time=1)` leading dimensions. This repository's [Isaac GR00T N1.7](../isaac-gr00t-n1.7/README.md) image serves that protocol directly. Policies speaking a different protocol, such as Cosmos 3 over the OpenPI WebSocket, need an adapter.

Two flags matter for getting comparable numbers:

- `--rename_map` maps simulation camera keys to the **policy's** feature names. The env
  publishes `rgb_ego` and `rgb_external_D455` (the client strips `rgb_`), while a GR00T
  finetune declares its own `video.modality_keys`. For the published SO-101 finetunes those
  are `front` and `wrist`, so the mapping is
  `'{"external_D455": "front", "ego": "wrist"}'`. Omit it and the server fails the request
  with `RuntimeError: Server error: 'front'`; invert it and the policy still runs but scores
  far lower, because it receives both views in the wrong slots.
- Read the expected keys from the checkpoint rather than guessing:
  `grep -A4 modality_keys <checkpoint>/experiment_cfg/conf.yaml`. The same file gives the
  action horizon (`action.delta_indices: 0..15` means 16).
- `--lang_instruction` must match the prompt the policy was trained with. The client's
  built-in default is `"Pick up the vial and place it in the rack"`, but the published
  finetunes expect `"Pick up the vial and place it in the yellow rack"`. Using the default
  measurably lowers the score.

Pick the eval env deliberately. `-Eval` fixes the robot to orange with no lighting or mat randomization, which is the closer proxy for a physical orange SO-101; `-DR-Eval` keeps full randomization and measures robustness instead.

### Success-rate floor

Measured on `Lerobot-So101-Teleop-Vials-To-Rack-Eval`, 30 episodes, `--action_horizon 16`:

| policy | success rate |
| --- | --- |
| random joint targets (sampled within the demonstration q01-q99 range) | **0/30 (0.0%)** |
| hold position (echo the observed joint state) | **0/30 (0.0%)** |

The task does not reward flailing: a random policy that stays inside the demonstrated
joint range still never places a vial. That makes the floor 0%, so any non-zero success
rate from a trained policy is a real signal rather than chance. Establish this baseline
before reading a policy's number — without it, a low score is not interpretable.

### Reference point: the published GR00T finetune

Before reading any new policy's number, reproduce a known-good one. Upstream publishes
GR00T finetunes of this task on Hugging Face, and this repository's
[Isaac GR00T N1.6](../isaac-gr00t-n1.6/README.md) image serves them directly. Measured on
`-Eval`, `--action_horizon 16`, one policy-server pod and one client pod on the same
Run:ai cluster:

| checkpoint | eval configuration | episodes | success |
| --- | --- | ---: | ---: |
| `..._vials_rack_left` (**sim-only**, the one the guide names) | official, nothing overridden | 3 x 50 | **104/150 (69.3%)** |
| `..._vials_rack_left_sim_and_real` | official `--rename_map` + "yellow rack" prompt | 10 | 5/10 (50.0%) |
| `..._vials_rack_left_sim_and_real` | inverted `--rename_map`, default prompt | 30 | 11/30 (36.7%) |

69.3% with a 95% Wilson interval of 61.5-76.2% sits at the top of the guide's stated 50-70%,
so the reference reproduces.

Two variables move this number, and both are easy to get wrong:

- **Which checkpoint.** The guide names the sim-only repo, whose training set was "75
  simulated demonstrations only". The `_sim_and_real` variant mixes in real-robot episodes
  and trades simulation score for transfer. They are different models; do not substitute one
  for the other and compare against the guide's band.
- **Which flags.** The bottom row differs from the middle only in `--rename_map` and
  `--lang_instruction`, and loses 13 points. **If a reference checkpoint scores far below
  its published number, suspect the eval configuration before the policy.**

#### The run-to-run spread is larger than it looks

The top row is three independent 50-episode runs, all at the client's default `--seed 1984`
against the same checkpoint:

| run | success | 450-step timeouts |
| --- | ---: | ---: |
| 1 | 34/50 (68.0%) | 16 |
| 2 | 37/50 (74.0%) | 13 |
| 3 | 33/50 (66.0%) | 17 |

A shared seed fixes the vial placements, so those runs saw **identical initial conditions**.
The 8-point spread therefore comes entirely from the policy server's diffusion sampling,
which the client's seed does not reach. Treat a single evaluation as a draw from a
distribution roughly +/-4 points wide at n=50, and do not seed-match your way out of it.

**A 10-episode result is close to meaningless here.** An earlier run of this exact
configuration scored 10/10 and read as "100%"; the first ten episodes of run 1 above, same
seed and same checkpoint, scored 8/10. Neither is the policy's rate. Quote at least 50
episodes, report the episode count with the rate, and never compare across counts — the
30-episode row above is not comparable to the 10-episode one.

Read success rates against the failure mode, not just the tally. Across all 150 episodes
there were exactly two outcomes: a success terminating between step 205 and 444, or a clean
450-step timeout. Successes equalled 50 minus the timeout count in every run, which is the
consistency check worth running before believing a number. A run whose episodes end after a
handful of steps is neither outcome, and is an environment fault.

The full recipe is in [Reproducing the published result](#reproducing-the-published-result)
below. Evidence, including the exact submitted scripts, is under
`artifacts/so101-workshop/evidence/` (gitignored).

Partial credit is more informative than the final tally when a policy scores 0. Count
grasps, not just placements: the random baseline grasps the vial 12 times in 30 episodes
while never placing it, so a trained policy with **zero** grasps is failing earlier and
differently than one that grasps and drops.

## Run On Run:ai

Evaluation is a non-interactive GPU job, so create the environment as a **Workspace**, following the same steps as the [Isaac Lab Headless Workspace](../isaac-lab/README.md) guide:

- Image URL
  ```
  j3soon/runai-sim-to-real-so101-workshop:latest
  ```
- Runtime settings
  - Command
    ```
    /run.sh "/workspace/isaaclab/_isaac_sim/python.sh -u -m sim_to_real_so101.scripts.list_envs"
    ```
  - Arguments: (Keep empty)
- Security
  - Set where the UID, GID, and supplementary groups for the container should be taken from
    ```
    From the image
    ```

Select the `<YOUR_LAB>-nfs` data source. A single-GPU compute resource is enough for one evaluation process.

For a real policy, the client and the server are different images, so run them as **two
workloads** and point `--policy_host` at the server pod's IP — no Kubernetes Service is
needed. See [Policy Server and Client Workloads](../../docs/policy-server-client.md) for
the pod-IP recipe and the Run:ai UI walkthrough. Co-locating both in one pod on two GPUs
also works and is simpler when the same image can do both, which is not the case here.

Two constraints specific to this client:

- The GR00T ZMQ server is `REQ`/`REP`, so it serves **one client at a time**. Point several
  eval clients at one server and all but the first stall until they time out. Scale out with
  one server per client, not one server shared by many.
- One evaluation is a single-GPU job, and this whole reproduction ran on **2 GPUs** (one
  server, one client). Adding GPUs does not make an evaluation faster — episodes are
  sequential — so scale episode count by running independent client/server pairs.

```sh
export SSL_CERT_FILE=$HOME/.runai/certs/root-ca.crt
runai training standard submit <name> \
  --project <project> --node-pools <pool> \
  --image j3soon/runai-sim-to-real-so101-workshop:latest --image-pull-policy Always \
  --gpu-devices-request 1 --large-shm \
  --nfs "server=<server>,path=<export>,mountpath=/mnt/nfs,readwrite" \
  --user-group-source fromTheImage \
  --command -- /run.sh "/workspace/isaaclab/_isaac_sim/python.sh -u -m sim_to_real_so101.scripts.list_envs"
```

Resolve the NFS server and export with `runai datasource describe <asset> --project <project> --type nfs --output json` rather than hard-coding them.

### Reproducing the published result

This is the full recipe that produced 104/150, as two workloads. It reproduces
[upstream's evaluation page](https://docs.nvidia.com/learning/physical-ai/sim-to-real-so-101/latest/11-sim-evaluation.html),
which runs both halves as two terminals in one container.

**Workload 1 — policy server** (`j3soon/runai-isaac-gr00t:n1.6`, 1 GPU):

```sh
CKPT_DIR=/mnt/nfs/<user>/so101/ref/grootn16-so101-simonly
export HF_TOKEN=<token> HF_HOME=/mnt/nfs/<user>/so101/hf_groot
uvx hf@latest download \
  aravindhs-NV/grootn16-finetune_sreetz-so101_teleop_vials_rack_left \
  --include 'checkpoint-10000/*' --local-dir "$CKPT_DIR"
hostname -i   # the client needs this
cd /workspace/gr00t
uv run python gr00t/eval/run_gr00t_server.py --model-path "$CKPT_DIR/checkpoint-10000"
```

**Workload 2 — evaluation client** (`j3soon/runai-sim-to-real-so101-workshop:latest`, 1 GPU):

```sh
/workspace/isaaclab/_isaac_sim/python.sh -u -m sim_to_real_so101.scripts.lerobot_eval \
    --task Lerobot-So101-Teleop-Vials-To-Rack-Eval \
    --rename_map '{"external_D455": "front", "ego": "wrist"}' \
    --action_horizon 16 \
    --lang_instruction "Pick up the vial and place it in the yellow rack" \
    --headless \
    --policy_host <server-pod-ip>
```

Points that decide whether this reproduces or not:

- **Pass the checkpoint path, not the repo root.** `checkpoint-10000/` is self-contained
  (`config.json`, both safetensors shards, `processor_config.json`, `statistics.json`,
  `embodiment_id.json`, `experiment_cfg/`), so `--include 'checkpoint-10000/*'` is the whole
  download. The repo root holds a second copy; fetching everything roughly doubles the
  transfer for nothing.
- **The server needs no flags beyond `--model-path`.** `ServerConfig` already defaults
  `embodiment_tag` to `NEW_EMBODIMENT`, `host` to `0.0.0.0` and `port` to `5555`, which is
  exactly what this checkpoint's `experiment_cfg/conf.yaml` declares. Passing
  `--embodiment-tag NEW_EMBODIMENT` is redundant, not wrong. Confirm from the server's own
  banner (`Embodiment tag: EmbodimentTag.NEW_EMBODIMENT`, `Port: 5555`) rather than assuming.
- **Do not clone Isaac-GR00T to serve.** The image already ships it at `/workspace/gr00t`
  (pinned, with `uv sync && uv pip install -e .` done at build). A
  `git clone --recurse-submodules` pulls LIBERO, SimplerEnv, robocasa and
  ManiSkill2_real2sim — over 40 minutes onto NFS, and the server imports none of them. That
  clone is only needed for upstream's RoboCasa evaluation path.
- **Leave the client's other defaults alone.** The guide passes no `--num_episodes`,
  `--num_envs`, `--seed` or `--policy_port`, so the run is 10 episodes at seed 1984 on the
  task's default env count. Setting any of them silently changes what "the published result"
  means.
- **`--policy_host` is the one necessary deviation.** The guide's `localhost` default assumes
  one container; server and client are different images here, so they are different pods. Re-read
  the pod IP after any restart — it changes.

Wall clock on this cluster: ~9 minutes for the server (8m39s of that is the 22GB image pull,
then a fast checkpoint load once the checkpoint is already on the shared mount), and ~35
minutes for 50 episodes plus Isaac Sim startup.

To raise the episode count, run **independent server+client pairs in parallel** rather than
one longer evaluation. Episodes are sequential within a client and the ZMQ server is
`REQ`/`REP`, so three pairs on 6 GPUs collect 150 episodes in the wall time of 50. Give each
client its own server; pointing several clients at one server stalls all but the first.

### Verifying a success rate before believing it

Success is a termination term and failure is the 450-step `time_out`, so a rate is only
meaningful alongside how the episodes ended. Extract the step at which each episode ended:

```sh
grep -aoE '\| [0-9]+/450' eval.log   # peaks then resets, once per episode
```

A healthy run mixes early terminations with 450s, for example
`[240, 255, 236, 268, 320, 240, 450, 232, 300, 450, ...]` — successes land between step 205
and 444. Cross-check that successes equal the episode count minus the number of 450s; if
they do not, the tally is not measuring what you think. A broken serving path gives *only*
clean 450-step timeouts. A run whose episodes all end after a handful of steps is neither —
it is an environment fault.

Note the client writes progress with `tqdm` carriage returns, so `grep -a` is required and a
redirected log holds one very long line per episode.

Recording and evaluation write under `outputs/` and `datasets/` inside the package directory, which upstream bind-mounts from the host and which are container-local here. Point them at the shared mount before a run:

```sh
mkdir -p /mnt/nfs/<YOUR_USERNAME>/so101/{outputs,datasets}
ln -sfn /mnt/nfs/<YOUR_USERNAME>/so101/outputs /workspace/Sim-to-Real-SO-101-Workshop/outputs
ln -sfn /mnt/nfs/<YOUR_USERNAME>/so101/datasets /workspace/Sim-to-Real-SO-101-Workshop/datasets
```

`docker/env` is copied to `/root/env` at build time and holds upstream's serial-port and camera-index defaults for the physical robot. It is irrelevant to the sim container but both `docker/utils.sh` and the entrypoint source it. Change values with the `setenv` helper rather than editing the file.

## Notes

- Upstream tags `v1.0`; the pinned commit is four commits later on `main`, and those four touch only the README and upstream's real-robot container, so this image matches `v1.0` for the sim container.
- Upstream states it is not accepting contributions, so carry local fixes here rather than sending them upstream.
- The base image, the LFS assets, and the Isaac Sim shader cache make this image large. Check its size locally after building.
- To evaluate a Cosmos 3 policy, see [Cosmos 3](../cosmos3/README.md). Cosmos 3 serves an HTTP `/predict` endpoint while this client speaks GR00T ZMQ, so the two need a protocol bridge.
- Isaac Sim 5.0 and 5.1 ship different PhysX builds, so contact-rich dynamics are not invariant across stacks. Compare evaluation results only against runs on the same stack.
