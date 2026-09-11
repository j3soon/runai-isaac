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

## Post-Training Notes

Behavior of this image that the upstream docs do not spell out, collected while adding a
custom action-policy recipe.

Two companion pages record that work in full:

- [SO-101 Action-Policy Post-Training](./so101-action-policy.md) — an end-to-end recipe,
  the serving-contract traps, the offline accuracy gate, and closed-loop results against a
  reproduced GR00T reference.
- [Measured Performance](./performance.md) — L40 throughput by batch size, 8-GPU scaling
  efficiency, and Edge vs Nano cost, for sizing a training run.

### The package runs from source, so an overlay needs no rebuild

The Dockerfile installs dependencies with `uv sync --no-install-project`, so
`cosmos_framework` itself is **not** installed into the venv — it is imported from the
cloned source at `/workspace`. New dataset classes, normalizer stats, and experiment
configs can therefore be bind-mounted straight into the package tree, which avoids a
rebuild of this ~32GB image on every code change:

```sh
docker run --rm --gpus all \
  -v "$PWD/my_dataset.py:/workspace/cosmos_framework/data/generator/action/datasets/my_dataset.py:ro" \
  -v "$PWD/my_stats.json:/workspace/cosmos_framework/data/generator/action/normalizer_stats/my_stats.json:ro" \
  ...
```

Two consequences:

- Use **absolute** paths for `-v` sources. Docker creates an empty *directory* when the
  source path does not exist, so a typo mounts a directory over the intended file and
  surfaces much later as `ModuleNotFoundError`, not as a mount error.
- Set `PYTHONPATH=/workspace` when running a script by absolute path
  (`python /some/script.py`). Python puts the *script's* directory on `sys.path`, not the
  working directory, so `import cosmos_framework` fails even with `WORKDIR=/workspace`.

### Do not bind-mount a Hugging Face snapshot subdirectory

Files under `hub/models--*/snapshots/<sha>/` are symlinks into the sibling `blobs/`
directory. Mounting only the snapshot directory leaves those symlinks dangling, and the
error names the path as if it were missing:

```
Error: Checkpoint path /vae/Wan2.2_VAE.pth does not exist.
```

Mount the whole cache and point the variable inside it instead:

```sh
-v ~/.cache/huggingface:/root/.cache/huggingface
-e WAN_VAE_PATH=/root/.cache/huggingface/hub/models--Wan-AI--Wan2.2-TI2V-5B/snapshots/<sha>/Wan2.2_VAE.pth
```

`ls -lL` on the host resolves the link and confirms the real ~2.8GB file before mounting.

### Registering a custom experiment

Experiments are registered by explicit import in `register_configs()` in
`cosmos_framework/configs/base/config.py`, not by scanning the `posttrain_config`
package (its `__init__.py` is empty). Rather than patching that upstream file, use a
launcher that imports the experiment module — populating the Hydra ConfigStore singleton
— then delegates to the stock trainer:

```python
import runpy
import cosmos_framework.configs.base.experiment.action.posttrain_config.my_experiment  # noqa: F401
runpy.run_module("cosmos_framework.scripts.train", run_name="__main__")
```

### A new embodiment must be registered

`ActionBaseDataset` calls `get_domain_id(domain_name)`, which raises `KeyError` for any
name absent from `EMBODIMENT_TO_DOMAIN_ID` in
`cosmos_framework/data/generator/action/domain_utils.py`. `num_embodiment_domains` is 32
and upstream uses ids up to 21, so free slots exist. Prefer an id above upstream's
highest over one of the low gaps, which upstream is likelier to fill: a collision would
alias the new embodiment onto another one's trained domain embedding.

### `train.py` CLI

- `opts` is a **positional** `argparse.REMAINDER`, not `--opts`. Pass Hydra overrides
  bare, after a `--` separator: `... --sft-toml <toml> -- trainer.max_iter=5 ...`.
  Passing `--opts key=value` exits with code 2, and `torchrun` reports only
  `ChildFailedError` with `exitcode: 2` and no traceback.
- Override paths are not the TOML paths. The TOML's `[model.parallelism]` section maps to
  `model.config.parallelism.*` as a Hydra override.
- `--dryrun` composes the config, writes it to
  `$IMAGINAIRE_OUTPUT_ROOT/<project>/<group>/<name>/config.yaml`, and exits. Run it before
  any GPU time.

### `exitcode: -9` after `Done with training.` is the OOM killer, not a hang

A run can log `Done with training.`, produce every result, then die during teardown with:

```
failed (exitcode: -9) local_rank: 0 ... ChildFailedError
traceback : Signal 9 (SIGKILL) received by PID <pid>
```

`torchrun` reports only the signal, so this reads like the interpreter-finalization hang
that `cosmos_framework/scripts/train.py` documents. **Check the kernel log before assuming
that**, because the symptom is identical and the cause usually is not:

```sh
dmesg | grep -iE "out of memory|oom-kill|killed process"
```

Measured locally on a 47GB host with ~26GB actually available, reproduced three times:
training logged `Done with training.`, then the kernel OOM-killed the process 60-105
seconds later, every time with `shmem-rss` of ~21.5GB against `anon-rss` of only ~2.7GB.

Upstream's `COSMOS_EXIT_WITHOUT_FINALIZE=1` does **not** help: the process dies before
`launch()` returns, so the flag's code path is never reached and its
`exiting without interpreter finalization` line never appears. That absent line is the
quickest way to tell a real finalization hang from this.

What did **not** change the ~21.5GB shared-memory footprint, each tested and ruled out:

- dropping `--ipc=host` in favour of an explicit `--shm-size=8g` (it is true in general
  that `--ipc=host` makes `--shm-size` a no-op, but that was not what held this memory)
- halving `dataloader.prefetch_factor` from 4 to 2
- `dataloader.num_workers=0` with `persistent_workers=False` and `prefetch_factor=null`,
  which removes dataloader worker processes entirely and still OOM-killed

So the dataloader is **not** the source and the actual owner of the mapping is **not
established**. What is established: training always completed and wrote its results, and
the kill always landed at teardown. The practical reading is that this workstation's
~26GB of available RAM is simply too little for this workload's teardown, which is a
local constraint rather than a defect in the recipe.

**Confirmed local-only.** The same recipe, same image, and same overlay run on a Run:ai
L40 node (1007GB RAM, 970GB available) finished with `Phase: Completed`, no OOM and no
`exitcode: -9`. So this is a workstation-RAM ceiling, not something to design around on
the cluster. Keep `--backoff-limit 0` regardless, so a finished run is never retried.

> Note: `num_workers=0` requires `prefetch_factor=null` and `persistent_workers=False`,
> or the dataloader raises before training starts. A partial override crashes early with
> `exitcode: 1`, which is easy to mistake for the OOM having been fixed.

> Read the kernel log through `journalctl -k`, not `dmesg`. On a host where the ring
> buffer is restricted, `dmesg` prints nothing and exits non-zero, which is easily
> misread as "no OOM occurred".

### The action policy server needs `HF_TOKEN` and its own `HF_HOME`

`action_policy_server_libero` pulls **`nvidia/Cosmos-Guardrail1`** during startup, which is
gated. Without a token it dies well after the model config is composed, so the failure
looks like a config problem rather than an access one:

```
Error: Access denied. This repository requires approval.
subprocess.CalledProcessError: Command '['uv', 'run', '--isolated', ... 'hf', 'download' ...
```

Accept the license once, then export `HF_TOKEN` for the server process.

Give the server a **separate `HF_HOME`** from any concurrently running training job. Two
processes downloading into one cache on NFS corrupt the xet state, and the resulting error
names neither the cache nor the repo:

```
RuntimeError: Task error: Unable to parse string as hex hash value
```

Deleting the shared cache is not an option while training is using it, so separate the
caches up front rather than after the collision.

The server also composes the **full** experiment config, dataloader included, so every
`${oc.env:...}` interpolation in the recipe must resolve even though serving never reads a
dataset. A training recipe that references `${oc.env:MY_DATA_ROOT}` fails at startup with
`KeyError: "Environment variable 'MY_DATA_ROOT' not found"`; export it (any valid path) for
the server process too.

### Serving a trained action policy

`action_policy_server_libero` serves any action experiment, not just LIBERO. It loads a
**training-time DCP checkpoint directory** directly, which avoids the export step:

```sh
python -m cosmos_framework.scripts.action_policy_server_libero \
  --experiment <your_experiment> \
  --experiment-overrides model.config.tokenizer.vae_path=<Wan2.2_VAE.pth> \
  --checkpoint-path <output>/<project>/<group>/<job>/checkpoints/iter_<N> \
  --action-normalization quantile --action-stats-path <your_stats.json> \
  --raw-action-dim <D> --fps <fps> --port 8001
```

Check it with `GET /info` (echoes the resolved checkpoint) and `POST /predict`
(`{"image": <base64 png>, "prompt": ..., "domain_name": ..., "image_size": N}`), which
returns `action` shaped `(chunk_length, raw_action_dim)` — already denormalized, and
already trimmed to `--raw-action-dim` rather than the padded `max_action_dim`. Verifying
that each returned dimension falls inside the training data's range is a cheap check that
the normalization stats round-trip correctly.

> `export_model` is **not** a usable alternative for every recipe. Its Cosmos3-Edge path
> requires the action dataset at `dataloader_train.dataloaders.action_data.dataloader.dataset`
> with a `list_of_datasets` entry. Recipes modelled on the Nano action experiments use
> `dataloader_train.dataloader.datasets.<name>.dataset` instead and fail with
> `Cosmos3 Edge export requires an action dataset config at ...`. Serve the DCP directly.

### `cannot pickle code objects` during checkpoint load hides the real error

A DCP load failure can surface as:

```
File ".../torch/distributed/checkpoint/state_dict_loader.py", line 283, in _load_state_dict
File ".../torch/distributed/checkpoint/utils.py", line 135, in gather_object
TypeError: cannot pickle code objects
```

Nothing there is about pickling. `torch.distributed.checkpoint` gathers each rank's result
across ranks; when a rank raises, the exception — carrying a traceback, which holds code
objects — is what fails to pickle. The pickling error therefore *replaces* the original
message. Re-run the same load on a single rank to see the real exception.

Serving a checkpoint is also not the same as loading a training base. Upstream's flow is to
export first, then serve the exported directory:

```sh
python -m cosmos_framework.scripts.export_model \
  --checkpoint-path <job>/checkpoints/iter_<N> -o <export-dir>
```

### `convert_model_to_dcp` resolves names, not Hugging Face repo ids

`--checkpoint-path` accepts either a **registered catalog name** or a **local directory**.
Anything else is treated as a relative local path, so `nvidia/Cosmos3-Edge-Policy-DROID`
fails with `Checkpoint directory does not exist: /workspace/nvidia/...`. The catalog holds
base checkpoints only:

```
Cosmos3-Edge  Cosmos3-Nano  Cosmos3-Super
Cosmos3-Super-Image2Video  Cosmos3-Super-Image2Video-4Step
Cosmos3-Super-Text2Image   Cosmos3-Super-Text2Image-4Step
```

To start from a policy checkpoint such as `Cosmos3-Edge-Policy-DROID`, download the repo
first and pass the resulting directory:

```sh
uvx hf@latest download nvidia/Cosmos3-Edge-Policy-DROID --local-dir <dir>
python -m cosmos_framework.scripts.convert_model_to_dcp -o <dcp-dir> --checkpoint-path <dir>
```

Converting `Cosmos3-Edge` produces a ~6.3GB DCP directory.

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
- Short free-text prompts suit larger checkpoints. `Cosmos3-Nano` rendered a four-element prompt as written, while `Cosmos3-Edge` dropped elements until upsampled. Add `--prompt-upsampling=True` for terse prompts, using the `=` form, since the space-separated form fails to parse on some checkpoints. It is a CLI override, not a sample-file key. A minimal custom sample is `{"name": ..., "model_mode": "text2image", "prompt": "..."}`.
- Upsampling rewrites the prompt with the reasoner in memory. `sample_args.json` keeps only the original, so read the expanded caption from the run log if you need it.
- Clean up with `docker rmi j3soon/runai-cosmos:3` (about 32GB) and by deleting the `models--nvidia--Cosmos3-*` directories under `~/.cache/huggingface/hub`.

## Run On Run:ai

Verified on a Run:ai cluster with the `prod` node pool, NVIDIA L40 (46GB), driver 580.105.08, CUDA 13.0.

```sh
export SSL_CERT_FILE=$HOME/.runai/certs/root-ca.crt
runai training standard submit <name> \
  --project <project> --node-pools prod \
  --image j3soon/runai-cosmos:3 --image-pull-policy Always \
  --gpu-devices-request 1 \
  --nfs "server=<server>,path=<export>,mountpath=/mnt/nfs,readwrite" \
  -e HF_HOME=/mnt/nfs/<user>/hf \
  --command -- /run.sh "python -m cosmos_framework.scripts.inference --parallelism-preset=latency -i inputs/omni/i2v.json -o /mnt/nfs/<user>/cosmos3/i2v --checkpoint-path Cosmos3-Edge --seed=0"
```

Notes:

- Resolve the NFS server and export with `runai datasource describe <asset> --project <project> --type nfs --output json` rather than hard-coding them.
- Keep `HF_HOME` on the NFS mount. The first run downloads about 16GB of checkpoints there and later jobs reuse them; container-local caches are lost when the pod exits.
- Add `-e HF_TOKEN=<token>` for gated repositories such as `Cosmos-Guardrail1`. It is readable through `runai workload describe`, so on a shared project ask an administrator for a credential asset and pass `--env-my-credentials type=genericSecret,name=HF_TOKEN,credential-name=<credential>,key=HF_TOKEN` instead. Creating one yourself typically fails with `403 Forbidden`.
- Do not nest double quotes inside `--command`; they are flattened before reaching the container and the command fails with a syntax error.
- `Cosmos3-Edge` fits the 46GB L40. `Cosmos3-Nano` leaves little headroom for video on that GPU.
- Verify outputs from a second workload. A pod can exit successfully with its output lost, and the run's `inputs/` entries are symlinks into a pod-local temp directory that does not survive.

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
