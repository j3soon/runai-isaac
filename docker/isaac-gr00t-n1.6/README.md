# Isaac GR00T N1.6

This page is part of the sample applications guide. Follow [README](../../README.md) first and stop interactive workloads when finished.

(Optional) Create a docker image for [Isaac GR00T](https://github.com/NVIDIA/Isaac-GR00T) (N1.6) following the [installation guide](https://github.com/NVIDIA/Isaac-GR00T):

```sh
docker build -f docker/isaac-gr00t-n1.6/Dockerfile . -t j3soon/runai-isaac-gr00t:n1.6
docker push j3soon/runai-isaac-gr00t:n1.6
```

> `docker/isaac-gr00t-n1.6/Dockerfile` is adapted from the upstream [`docker/Dockerfile`](https://github.com/NVIDIA/Isaac-GR00T/tree/main/docker) for GR00T N1.6.

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
