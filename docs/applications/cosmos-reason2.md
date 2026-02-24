# Cosmos-Reason2

This page is part of the sample applications guide. Follow [README](../../README.md) first and stop interactive workloads when finished.

(Optional) Create a docker image for [cosmos-reason2](https://github.com/nvidia-cosmos/cosmos-reason2).

`docker/cosmos-reason2/Dockerfile` is a self-contained local variant that clones the upstream repo at a pinned commit during the build.

```sh
docker build -f docker/cosmos-reason2/Dockerfile . -t j3soon/runai-cosmos-reason:2
docker push j3soon/runai-cosmos-reason:2
```

> Environment command:

> ```
> /run.sh "uv pip install jupyterlab" "jupyter lab --ip=0.0.0.0 --no-browser --allow-root --NotebookApp.base_url=/${RUNAI_PROJECT}/${RUNAI_JOB_NAME} --NotebookApp.token='' --notebook-dir=/"
> ```

## Run In Jupyter Lab

> Below is usage guide specific for this image.

Follow the [setup guide](https://github.com/nvidia-cosmos/cosmos-reason2#setup):

```sh
git clone https://github.com/nvidia-cosmos/cosmos-reason2
cd cosmos-reason2
git config --global --add safe.directory $(pwd)
export HF_HOME="$(pwd)/.cache/huggingface"
hf auth login
# and enter a read-only HF token (no need for git credentials)
```

Agree HF License for the models:
- https://huggingface.co/nvidia/Cosmos-Reason2-2B

Run the [minimal Transformers inference example](https://github.com/nvidia-cosmos/cosmos-reason2?tab=readme-ov-file#transformers):

```sh
export HF_HOME="$(pwd)/.cache/huggingface"
python scripts/inference_sample.py
```

Run [vLLM online serving](https://github.com/nvidia-cosmos/cosmos-reason2?tab=readme-ov-file#online-serving) and sample inference:

```sh
vllm serve nvidia/Cosmos-Reason2-2B \
  --allowed-local-media-path "$(pwd)" \
  --max-model-len 16384 \
  --media-io-kwargs '{"video": {"num_frames": -1}}' \
  --reasoning-parser qwen3 \
  --port 8000
```

In another terminal:

```sh
cosmos-reason2-inference online --port 8000 -i prompts/caption.yaml --reasoning --videos assets/sample.mp4 --fps 4
```

Follow the [upstream README](https://github.com/nvidia-cosmos/cosmos-reason2) for more deployment, offline inference, post-training, and quantization workflows.
