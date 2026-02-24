# Cosmos-Transfer2.5

This page is part of the sample applications guide. Follow [README](../../README.md) first and stop interactive workloads when finished.

Create a docker image for [cosmos-transfer2.5](https://github.com/nvidia-cosmos/cosmos-transfer2.5).

`docker/cosmos-transfer2.5/Dockerfile` is a self-contained local variant that clones the upstream repo at a pinned commit during the build.

```sh
docker build -f docker/cosmos-transfer2.5/Dockerfile . -t j3soon/runai-cosmos-transfer:2.5
docker push j3soon/runai-cosmos-transfer:2.5
```

> Environment command:

> ```
> /run.sh "uv pip install jupyterlab" "jupyter lab --ip=0.0.0.0 --no-browser --allow-root --NotebookApp.base_url=/${RUNAI_PROJECT}/${RUNAI_JOB_NAME} --NotebookApp.token='' --notebook-dir=/"
> ```

## Run In Jupyter Lab

> Below is usage guide specific for this image.

Follow the [setup guide](https://github.com/nvidia-cosmos/cosmos-transfer2.5/blob/main/docs/setup.md):

```sh
git clone https://github.com/nvidia-cosmos/cosmos-transfer2.5
cd cosmos-transfer2.5
git config --global --add safe.directory $(pwd)
git lfs pull
uv tool install -U "huggingface_hub[cli]"
export HF_HOME="$(pwd)/.cache/huggingface"
hf auth login
# and enter a read-only HF token (no need for git credentials)
```

Agree HF License for the models:
- https://huggingface.co/nvidia/Cosmos-Guardrail1
- https://huggingface.co/nvidia/Cosmos-Transfer2.5-2B

Follow the [inference guide](https://github.com/nvidia-cosmos/cosmos-transfer2.5/blob/main/docs/inference.md):

```sh
export HF_HOME="$(pwd)/.cache/huggingface"

python examples/inference.py -i assets/robot_example/depth/robot_depth_spec.json -o outputs/depth
```

Follow the [user guide](https://github.com/nvidia-cosmos/cosmos-transfer2.5/tree/main?tab=readme-ov-file#user-guide) for more.
