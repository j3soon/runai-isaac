# Isaac GR00T N1.6

This page is part of the sample applications guide. Follow [README](../../README.md) first and stop interactive workloads when finished.

(Optional) Create a docker image for [Isaac GR00T](https://github.com/NVIDIA/Isaac-GR00T) (N1.6) following the [installation guide](https://github.com/NVIDIA/Isaac-GR00T):

```sh
docker build -f docker/isaac-gr00t-n1.6/Dockerfile . -t j3soon/runai-isaac-gr00t:n1.6
docker push j3soon/runai-isaac-gr00t:n1.6
```

> `docker/isaac-gr00t-n1.6/Dockerfile` is adapted from the upstream [`docker/Dockerfile`](https://github.com/NVIDIA/Isaac-GR00T/tree/main/docker) for GR00T N1.6.

> This image does **not** serve [RoboLab](../robolab/README.md)'s GR00T policy client, which targets GR00T **N1.7** (`nvidia/GR00T-N1.7-DROID`). Use the [Isaac GR00T N1.7](../isaac-gr00t-n1.7/README.md) image for that.

> Environment command:
>
> ```
> /run.sh "uv run jupyter lab --ip=0.0.0.0 --no-browser --allow-root --NotebookApp.base_url=/${RUNAI_PROJECT}/${RUNAI_JOB_NAME} --NotebookApp.token='' --notebook-dir=/"
> ```

## Run In Jupyter Lab

> Below is usage guide specific for this image.

Follow the [quick start guide](https://github.com/NVIDIA/Isaac-GR00T?tab=readme-ov-file#quick-start):

```sh
# git clone --recurse-submodules https://github.com/NVIDIA/Isaac-GR00T
# Clone the patched repository instead
git clone --recurse-submodules -b dev https://github.com/j3soon/Isaac-GR00T
cd Isaac-GR00T
apt update && apt install git-lfs
git lfs pull
```

```sh
export HF_HOME="$(pwd)/.cache/huggingface"
uv run python gr00t/eval/run_gr00t_server.py --embodiment-tag GR1 --model-path nvidia/GR00T-N1.6-3B
```

Inference:

```sh
export HF_HOME="$(pwd)/.cache/huggingface"
uv run python scripts/deployment/standalone_inference_script.py \
  --model-path nvidia/GR00T-N1.6-3B \
  --dataset-path demo_data/gr1.PickNPlace \
  --embodiment-tag GR1 \
  --traj-ids 0 1 2 \
  --inference-mode pytorch \
  --action-horizon 8
```

### RoboCasa GR1 Tabletop Tasks

Follow [the README](https://github.com/NVIDIA/Isaac-GR00T/blob/main/examples/robocasa-gr1-tabletop-tasks/README.md):

```sh
sudo apt update
sudo apt install libegl1-mesa-dev libglu1-mesa
git config --global --add safe.directory $(pwd)
bash gr00t/eval/sim/robocasa-gr1-tabletop-tasks/setup_RoboCasaGR1TabletopTasks.sh
```

run server:

```sh
uv run python gr00t/eval/run_gr00t_server.py \
    --model-path nvidia/GR00T-N1.6-3B \
    --embodiment-tag GR1 \
    --use-sim-policy-wrapper
```

run client:

```sh
gr00t/eval/sim/robocasa-gr1-tabletop-tasks/robocasa_uv/.venv/bin/python gr00t/eval/rollout_policy.py \
    --n_episodes 10 \
    --policy_client_host 127.0.0.1 \
    --policy_client_port 5555 \
    --max_episode_steps=720 \
    --env_name gr1_unified/PnPBottleToCabinetClose_GR1ArmsAndWaistFourierHands_Env \
    --n_action_steps 8 \
    --n_envs 5
```

### Serving a Finetuned Checkpoint

`run_gr00t_server.py` also serves a community finetune, which is how the SO-101 vial-to-rack
policy is evaluated against the
[Sim-to-Real SO-101 Workshop](../sim-to-real-so101-workshop/README.md) client:

```sh
cd /workspace/gr00t
uv run python gr00t/eval/run_gr00t_server.py --model-path <local-checkpoint-dir>
```

`--model-path` is the only flag needed for such a checkpoint, because `ServerConfig` already
defaults `embodiment_tag` to `NEW_EMBODIMENT`, `host` to `0.0.0.0` and `port` to `5555`.

The image already contains the repository at `/workspace/gr00t` (upstream `NVIDIA/Isaac-GR00T`
at the pinned commit in the Dockerfile, with `uv sync && uv pip install -e .` run at build
time), so serving needs **no clone at all**. The `git clone --recurse-submodules` in the
quick-start above is for the RoboCasa evaluation path: those submodules are LIBERO,
SimplerEnv, robocasa and ManiSkill2_real2sim, they take over 40 minutes to check out onto an
NFS mount, and `run_gr00t_server.py` imports none of them. Cloning to serve is the single
biggest avoidable delay in bringing a policy server up.

CLI details that cost time:

- `--embodiment-tag` is a `tyro` enum and takes the **uppercase** member name, so
  `NEW_EMBODIMENT`, not the `new_embodiment` string that appears in checkpoint metadata. It
  is also already the default, so a `new_embodiment` checkpoint needs no flag.
- Only `--model-path` is required. Its value is the **checkpoint directory**
  (`.../checkpoint-10000`), not the repo root; a published finetune usually carries a
  self-contained copy of `config.json`, the safetensors shards, `processor_config.json`,
  `statistics.json`, `embodiment_id.json` and `experiment_cfg/` inside each checkpoint, so
  `--include 'checkpoint-N/*'` is the whole download.
- The startup banner echoes the resolved `Embodiment tag`, `Model path`, `Host` and `Port`.
  Read it instead of assuming the defaults took effect.
- `tyro` booleans are bare flags. `--use-state True` fails with
  `Unrecognized options: True`; write `--use-state`, and omit the flag for false.
- The checkpoint declares the observation contract it expects. Read
  `<checkpoint>/experiment_cfg/conf.yaml` for `video.modality_keys` (the camera names the
  client must send) and `action.delta_indices` (the action horizon) instead of guessing.
- The server is ZMQ `REQ`/`REP` and serves one client at a time. See
  [Policy Server and Client Workloads](../../docs/policy-server-client.md).

Downloading the checkpoint to the NFS mount rather than the pod keeps it across the restarts
that the idle-GPU timeout causes.
