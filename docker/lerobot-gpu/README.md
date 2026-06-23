# LeRobot GPU

This page is part of the sample applications guide. Follow [README](../../README.md) first and stop interactive workloads when finished.

(Optional) Create a docker image for LeRobot GPU by following the upstream [LeRobot docker setup](https://github.com/huggingface/lerobot/tree/8fff0fde7c79f23a93d845d1a50e985de01f8b8a/docker) and using the pinned `v0.4.4` source in this repository's Dockerfile.

```sh
docker build -f docker/lerobot-gpu/Dockerfile . -t j3soon/runai-lerobot-gpu:0.4.4
docker push j3soon/runai-lerobot-gpu:0.4.4
```

`docker/lerobot-gpu/Dockerfile` is a self-contained local variant adapted from the upstream `docker/Dockerfile.internal` at LeRobot `v0.4.4`.

> Environment command:
>
> ```
> /run.sh "uv pip install jupyterlab" "uv run jupyter lab --ip=0.0.0.0 --no-browser --allow-root --NotebookApp.base_url=/${RUNAI_PROJECT}/${RUNAI_JOB_NAME} --NotebookApp.token='' --notebook-dir=/"
> ```

## Run In Jupyter Lab

> Below is a simple training flow based on the [LeRobot training guide](https://huggingface.co/docs/lerobot/main/en/il_robots).

The Dockerfile clones the LeRobot source tree into `/lerobot` during the image build.

```sh
cd /lerobot
git config --global --add safe.directory /lerobot
hf auth login
wandb login
```

If you already have a dataset on the Hugging Face Hub, set your username and start training:

```sh
HF_USER=$(NO_COLOR=1 hf auth whoami | awk -F': *' 'NR==1 {print $2}')

lerobot-train \
  --dataset.repo_id=${HF_USER}/so101_test \
  --policy.type=act \
  --output_dir=outputs/train/act_so101_test \
  --job_name=act_so101_test \
  --policy.device=cuda \
  --wandb.enable=true \
  --policy.repo_id=${HF_USER}/my_policy \
  --policy.private=true
```

Checkpoints are written to:

```sh
ls outputs/train/act_so101_test/checkpoints
```

To resume from the latest checkpoint:

```sh
lerobot-train \
  --config_path=outputs/train/act_so101_test/checkpoints/last/pretrained_model/train_config.json \
  --resume=true
```

If you need to create a dataset first, follow the upstream [Imitation Learning on Real-World Robots](https://huggingface.co/docs/lerobot/main/en/il_robots) guide for teleoperation, recording, replay, and evaluation steps.
