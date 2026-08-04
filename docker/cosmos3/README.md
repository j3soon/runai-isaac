# Cosmos 3

This page is part of the sample applications guide. Follow [README](../../README.md) first and stop interactive workloads when finished.

(Optional) Create a docker image for [Cosmos 3](https://github.com/NVIDIA/cosmos), which is installed through the [cosmos-framework](https://github.com/NVIDIA/cosmos-framework) training and inference package.

Cosmos 3 replaces the separate Cosmos-Predict/Transfer/Reason products with a single omnimodal model family. One image therefore covers both runtime surfaces:

- **Reasoner**: takes text and vision, outputs text (understanding, reasoning, planning).
- **Generator**: takes text, vision, sound, and actions, outputs vision, sound, and actions.

`docker/cosmos3/Dockerfile` is a self-contained local variant that clones the upstream repo at a pinned commit during the build. It installs the CUDA 13.0 variant (`--group=cu130-train`), which is the upstream-recommended configuration and covers both inference and post-training.

The image does not include vLLM: upstream declares the `vllm` dependency group mutually exclusive with every CUDA group, so it cannot share this virtual environment. For OpenAI-compatible serving, use the [`vllm/vllm-omni:cosmos3`](https://github.com/NVIDIA/cosmos/tree/main/cookbooks/cosmos3) container that upstream publishes for that purpose.

```sh
docker build -f docker/cosmos3/Dockerfile . -t j3soon/runai-cosmos:3
docker push j3soon/runai-cosmos:3
```

> Environment command:

> ```
> /run.sh "uv pip install jupyterlab" "jupyter lab --ip=0.0.0.0 --no-browser --allow-root --NotebookApp.base_url=/${RUNAI_PROJECT}/${RUNAI_JOB_NAME} --NotebookApp.token='' --notebook-dir=/"
> ```

## Run In Jupyter Lab

> Below is usage guide specific for this image.

Follow the [setup guide](https://github.com/NVIDIA/cosmos-framework/blob/main/docs/setup.md):

```sh
git clone https://github.com/NVIDIA/cosmos-framework
cd cosmos-framework
git config --global --add safe.directory $(pwd)
export HF_HOME="$(pwd)/.cache/huggingface"
uvx hf@latest auth login
# and enter a read-only HF token (no need for git credentials)
```

For non-interactive workloads, set the `HF_TOKEN` environment variable on the workload instead of logging in. Do not set both with different tokens.

Agree HF License for the models you plan to use:
- https://huggingface.co/nvidia/Cosmos-Guardrail1
- https://huggingface.co/nvidia/Cosmos3-Edge
- https://huggingface.co/nvidia/Cosmos3-Nano
- https://huggingface.co/nvidia/Cosmos3-Super

Verify checkpoint access before launching a long run:

```sh
uvx hf@latest download --repo-type model nvidia/Cosmos-Guardrail1 \
  --revision d6d4bfa899a71454a700907664f3e88f503950cf --include "README.md"
```

Follow the [inference guide](https://github.com/NVIDIA/cosmos-framework/blob/main/docs/inference.md). Single-GPU, using the 2B `Cosmos3-Edge` checkpoint:

```sh
export HF_HOME="$(pwd)/.cache/huggingface"

python -m cosmos_framework.scripts.inference \
    --parallelism-preset=latency \
    -i "inputs/omni/t2i.json" \
    -o outputs/omni_edge \
    --checkpoint-path Cosmos3-Edge \
    --seed=0
```

Multi-GPU, using the 16B `Cosmos3-Nano` checkpoint (weights are FSDP-sharded across all ranks):

```sh
torchrun --nproc-per-node=8 -m cosmos_framework.scripts.inference \
    --parallelism-preset=throughput \
    -i "inputs/omni/*.json" \
    -o outputs/omni_nano \
    --checkpoint-path Cosmos3-Nano \
    --seed=0
```

The same 8-GPU command runs the 64B `Cosmos3-Super` checkpoint on 8x80GB GPUs. `Cosmos3-Super` does not fit on a single 80GB GPU. `Cosmos3-Edge` supports every mode except audio (`enable_sound`), since its checkpoint ships without a sound tokenizer.

Outputs are written per sample under the `-o` directory as `sample_args.json`, `sample_outputs.json`, `vision.jpg`, and `vision.mp4`.

> Note: guardrails are enabled by default, but the safety check is fail-open. If a stage has no safety model loaded it logs `No safety models found, returning safe` and passes the sample through. Check the run log rather than assuming every stage filtered.

Follow the [training guide](https://github.com/NVIDIA/cosmos-framework/blob/main/docs/training.md) for post-training, and the [Cosmos 3 cookbooks](https://github.com/NVIDIA/cosmos/tree/main/cookbooks/cosmos3) for end-to-end generator, reasoner, and action workflows.

## Run Locally

To smoke-test the image outside Run:ai, on a machine with an NVIDIA GPU and the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html). Mount the Hugging Face cache so checkpoints persist across runs, and write outputs under this repository's gitignored `artifacts/` directory:

```sh
mkdir -p ~/.cache/huggingface artifacts/cosmos3
docker run --rm --gpus all --ipc=host \
  -e HF_TOKEN="$HF_TOKEN" \
  -e HF_HOME=/root/.cache/huggingface \
  -v ~/.cache/huggingface:/root/.cache/huggingface \
  -v "$(pwd)/artifacts/cosmos3:/workspace/outputs" \
  j3soon/runai-cosmos:3 \
  python -m cosmos_framework.scripts.inference \
      --parallelism-preset=latency \
      -i "inputs/omni/t2i.json" \
      -o /workspace/outputs/omni_edge \
      --checkpoint-path Cosmos3-Edge \
      --seed=0
```

The generated image is written to `artifacts/cosmos3/omni_edge/t2i/vision.jpg`, alongside `sample_args.json`, `sample_outputs.json`, and the run logs.

Notes:

- The first run downloads about 16GB of checkpoints (`Cosmos3-Edge`, `Cosmos-Guardrail1`, `Qwen3Guard-Gen-0.6B`, and the `Wan-AI/Wan2.2-TI2V-5B` VAE) into the mounted cache. Later runs reuse them.
- The container runs as root, so outputs are root-owned on the host. Reclaim them with `sudo chown -R "$(id -u):$(id -g)" artifacts/cosmos3`. Do not add `--user`: the virtual environment at `/workspace/.venv` is not readable by other users and the run fails immediately.
- `--ipc=host` gives the container the host's shared memory. If your security policy disallows it, raise `--shm-size` instead.
- `--seed=0` reproduces the same scene across runs, but not byte-identical files. Do not diff output bytes to check reproducibility.
- Clean up with `docker rmi j3soon/runai-cosmos:3` (about 32GB) and by deleting the `models--nvidia--Cosmos3-*` directories under `~/.cache/huggingface/hub`.

## Storage And Environment Variables

Container-local data is lost when the workload stops, and Cosmos 3 caches and outputs are large. Upstream recommends ~150GiB free for a first inference or training run (~90GiB Hugging Face cache, ~20GiB uv cache, ~30GiB outputs), and >=1TB for sustained training. Point the following at a persistent mount such as `/mnt/nfs/<user>` instead of the container filesystem:

| Variable | Purpose |
| --- | --- |
| `HF_TOKEN` | Hugging Face token for gated downloads. Alternative to `uvx hf@latest auth login`. |
| `HF_HOME` | Cache directory for Hugging Face models and datasets. |
| `IMAGINAIRE_OUTPUT_ROOT` | Output root for training checkpoints and logs. |
| `UV_CACHE_DIR` | Cache directory for `uv`-managed dependencies. |

Multi-node training additionally requires a working NCCL setup and a shared filesystem visible to all ranks for checkpoint I/O.

If `import torch` fails with `ImportError: cannot import name '_functionalization' from 'torch._C'`, clear the host library path in the current shell before running, as described in the upstream [troubleshooting section](https://github.com/NVIDIA/cosmos-framework/blob/main/docs/setup.md#pytorch-import-issue):

```sh
export LD_LIBRARY_PATH=
```
