# FastWAM

This page is part of the sample applications guide. Follow [README](../../README.md) first and stop interactive workloads when finished.

(Optional) Create a docker image for [FastWAM](https://github.com/yuantianyuan01/FastWAM), the official codebase for *Fast-WAM: Do World Action Models Need Test-time Future Imagination?* ([arXiv:2603.16666](https://arxiv.org/abs/2603.16666)). A world action model normally imagines a future video clip at test time and reads the action out of it; FastWAM asks whether that step is needed, and its Optional IDM variant answers both ways from one checkpoint — **IDM mode** imagines first, **first-frame mode** predicts actions directly from the current observation. The repository covers training and closed-loop evaluation on the LIBERO and RoboTwin manipulation benchmarks.

`docker/fastwam/Dockerfile` is a self-contained image built from upstream's [`Environment Setup`](https://github.com/yuantianyuan01/FastWAM/tree/7faa71108368fbb3b6885649f112af607427a2d4#environment-setup) instructions, since upstream ships no Dockerfile. It clones FastWAM at a pinned commit, installs the pinned `torch 2.7.1+cu128` stack on a CUDA 12.8 base, and additionally installs the LIBERO benchmark environment that upstream tells you to set up separately.

> **The pin is a commit, not a tag.** FastWAM publishes no git tags and no releases, and its `pyproject.toml` version has stayed at `0.1.0` across the Optional IDM and 2x-inference updates, so a commit SHA is the only ref that identifies a build. This image pins `7faa7110` (2026-08-20, `Optimize IDM action-only inference`). LIBERO is pinned alongside it at [`8f1084e3`](https://github.com/Lifelong-Robot-Learning/LIBERO/commit/8f1084e3132a39270c3a13ebe37270a43ece2a01) (2025-03-15), the head of its `master` branch, which also carries no release tag.

> Only the LIBERO benchmark is installed. RoboTwin needs a separate platform install and its own asset download, which upstream also leaves to the user; the `third_party/RoboTwin` evaluation code and `experiments/robotwin/` are present in the image but the simulator behind them is not. See [Limitations](#limitations).

```sh
docker build -f docker/fastwam/Dockerfile . -t j3soon/runai-fastwam:latest
docker push j3soon/runai-fastwam:latest
```

> Environment command:
>
> ```
> /run.sh "python experiments/libero/run_libero_manager.py task=libero_uncond_2cam224_1e-4 ckpt=/mnt/nfs/<YOUR_USERNAME>/fastwam/checkpoints/fastwam_release/libero_uncond_2cam224.pt EVALUATION.dataset_stats_path=/mnt/nfs/<YOUR_USERNAME>/fastwam/checkpoints/fastwam_release/libero_uncond_2cam224_dataset_stats.json EVALUATION.sigma_shift=5.0 MULTIRUN.num_gpus=8 model.redirect_common_files=false"
> ```
>
> FastWAM is installed with `pip install -e .` into a virtual environment that is already on `PATH`, so use a plain `python` and `pip install ...` (not `uv pip install`) when adding packages. The image pins `huggingface-hub` to FastWAM's `0.29.2`, which predates the `hf` CLI, so download models with `huggingface-cli download` as upstream's README does. The image sets `PYTHONUNBUFFERED=1`, without which the evaluation manager's per-task progress lines stay buffered and a healthy run looks hung.

> Use `/run.sh --shell "..."` whenever the command contains quotes, `&&`, a pipe or a redirect. Without `--shell`, `/run.sh` word-splits the command instead of running it through a shell, and a quoted `sed` expression or a `&&` chain arrives as literal arguments. Several commands on this page need it.

## Run On Run:ai

FastWAM training and evaluation are non-interactive multi-GPU jobs, so create the environment as a **Workspace** with the command above, following the same steps as the [Isaac Lab Headless Workspace](../isaac-lab/README.md) guide:

- Image URL
  ```
  j3soon/runai-fastwam:latest
  ```
- Runtime settings
  - Command
    ```
    /run.sh "python experiments/libero/run_libero_manager.py task=libero_uncond_2cam224_1e-4 ckpt=/mnt/nfs/<YOUR_USERNAME>/fastwam/checkpoints/fastwam_release/libero_uncond_2cam224.pt EVALUATION.dataset_stats_path=/mnt/nfs/<YOUR_USERNAME>/fastwam/checkpoints/fastwam_release/libero_uncond_2cam224_dataset_stats.json EVALUATION.sigma_shift=5.0 MULTIRUN.num_gpus=8 model.redirect_common_files=false"
    ```
  - Arguments: (Keep empty)
  - Environment variable
    - `DIFFSYNTH_MODEL_BASE_PATH` = `/mnt/nfs/<YOUR_USERNAME>/fastwam/checkpoints`
    - `DIFFSYNTH_DOWNLOAD_SOURCE` = `huggingface` (see [Backbone Downloads](#backbone-downloads))
- Compute resource: request 8 GPUs for the defaults on this page. Both `configs/sim_libero.yaml` and `configs/sim_robotwin.yaml` set `MULTIRUN.num_gpus=8`; pass a smaller value such as `MULTIRUN.num_gpus=4` to match a smaller request, or the manager waits on workers that never start.
- Data source: an NFS mount at `/mnt/nfs`, for the backbone, checkpoints, datasets and run outputs.

## Backbone Downloads

FastWAM builds its ActionDiT from Wan2.2-TI2V-5B, so the first run downloads a large set of weights. All of them are public and need no Hugging Face token.

| Artifact | Size | Needed for |
| --- | ---: | --- |
| `Wan-AI/Wan2.2-TI2V-5B` DiT (`diffusion_pytorch_model*.safetensors`) | 20.0GB | Model preparation, training, inference |
| `Wan-AI/Wan2.2-TI2V-5B` VAE (`Wan2.2_VAE.pth`) | 2.8GB | Model preparation, training, inference |
| `Wan-AI/Wan2.2-TI2V-5B` T5 text encoder (`models_t5_umt5-xxl-enc-bf16.pth`) | 11.4GB | Text-embedding precompute; also fetched by model preparation |
| `Wan-AI/Wan2.1-T2V-1.3B` umt5-xxl tokenizer (`google/umt5-xxl/`) | <0.1GB | Same as above |
| `yuanty/fastwam` released checkpoint (each) | 12.0GB | Inference with released checkpoints |

> **Evaluation does not need the 20GB DiT.** `configs/sim_libero.yaml` sets `model.skip_dit_load_from_pretrain: true`, so the released checkpoint supplies the video expert and only the VAE, the text encoder and the tokenizer are fetched — about 14.2GB plus the 12.0GB checkpoint. The DiT download belongs to model preparation and training.

> **Set `DIFFSYNTH_DOWNLOAD_SOURCE=huggingface`.** FastWAM's loader (`src/fastwam/models/wan22/helpers/io.py`) defaults to **ModelScope**, which is slow from outside China: measured from one host on 2026-09-11, the same T5 file pulled at **2.7MB/s** from ModelScope and **49.6MB/s** from Hugging Face. On the ModelScope path that one file alone is a ~1.5 hour download.

> Switching source also requires `redirect_common_files: false`, and this is not optional. With the default `true`, the loader redirects the VAE and the text encoder away from `Wan-AI/Wan2.2-TI2V-5B` to `DiffSynth-Studio/Wan-Series-Converted-Safetensors`, which exists **only on ModelScope** — Hugging Face has no such repository, so the download fails. Setting it to `false` asks for the original `.pth` files inside `Wan-AI/Wan2.2-TI2V-5B`, which are present on Hugging Face.
>
> The hydra entrypoints (`scripts/train.py`, `scripts/precompute_text_embeds.py`, `experiments/libero/run_libero_manager.py`, `scripts/dryrun_fastwam.py`) take it as a command-line override:
>
> ```
> model.redirect_common_files=false
> ```
>
> `scripts/preprocess_action_dit_backbone.py` is the exception: it reads the YAML file directly via `--model-config` and accepts no overrides, so edit the file for that one step (shown below).

## Model Preparation

Required before both training and inference. It interpolates the ActionDiT backbone out of the Wan2.2 DiT and writes a `.pt` payload that the model configs reference by path.

```sh
docker run --rm --gpus all --ipc=host \
  -e DIFFSYNTH_DOWNLOAD_SOURCE=huggingface \
  -v "$HOME/.cache/fastwam/checkpoints:/workspace/fastwam/checkpoints" \
  j3soon/runai-fastwam:latest /run.sh --shell \
  "sed -i 's/^redirect_common_files: true/redirect_common_files: false/' configs/model/fastwam.yaml && \
   python scripts/preprocess_action_dit_backbone.py \
     --model-config configs/model/fastwam.yaml \
     --output checkpoints/ActionDiT_linear_interp_Wan22_alphascale_1024hdim.pt \
     --device cuda --dtype bfloat16"
```

`DIFFSYNTH_MODEL_BASE_PATH` defaults to `/workspace/fastwam/checkpoints` in this image, which is upstream's `export DIFFSYNTH_MODEL_BASE_PATH="$(pwd)/checkpoints"`. The mount above puts that directory on the host so the ~34GB of weights survive the container; on Run:ai, point the variable at `/mnt/nfs/<YOUR_USERNAME>/...` instead. It writes a ~2.0GB `.pt` payload.

> **This step needs more than 32GB of host RAM**, which is a CPU-memory requirement, not a GPU one. It materializes the 20GB bf16 DiT on the CPU before interpolating, and a 32GB container cap killed it at 33.4GB resident with `exit=137` and no Python traceback — the log simply ends after `Preprocessing ActionDiT backbone`. The same command at a 44GB cap completed. If you cap memory locally (and you should, so a kill stays inside the container's cgroup), set `--memory` above 40GB, and keep `--memory-swap` equal to it or the cap does not bind.

> This step downloads the T5 text encoder (11.4GB) that it never uses. `configs/model/fastwam.yaml` sets `load_text_encoder: false`, but `preprocess_action_dit_backbone.py` does not forward that field, and `load_wan22_ti2v_5b_components()` defaults it to `True`. The download is not wasted — the text-embedding precompute step needs the same file — but budget for it here rather than being surprised.

## Inference With Released Checkpoints

The released checkpoints are public and ungated:

```sh
docker run --rm --gpus all --ipc=host \
  -v "$HOME/.cache/fastwam/checkpoints:/workspace/fastwam/checkpoints" \
  j3soon/runai-fastwam:latest /run.sh --shell \
  "huggingface-cli download yuanty/fastwam \
     libero_uncond_2cam224.pt libero_uncond_2cam224_dataset_stats.json \
     --local-dir ./checkpoints/fastwam_release"
```

Then evaluate. The manager runs one persistent model worker per GPU, quarantines bad GPUs, and writes resumable results, so `MULTIRUN.num_gpus` must match the GPUs you actually have:

```sh
docker run --rm --gpus all --ipc=host \
  -e DIFFSYNTH_DOWNLOAD_SOURCE=huggingface \
  -v "$HOME/.cache/fastwam/checkpoints:/workspace/fastwam/checkpoints" \
  -v "$PWD/artifacts/fastwam/evaluate_results:/workspace/fastwam/evaluate_results" \
  j3soon/runai-fastwam:latest /run.sh \
  "python experiments/libero/run_libero_manager.py task=libero_uncond_2cam224_1e-4 ckpt=./checkpoints/fastwam_release/libero_uncond_2cam224.pt EVALUATION.dataset_stats_path=./checkpoints/fastwam_release/libero_uncond_2cam224_dataset_stats.json EVALUATION.sigma_shift=5.0 MULTIRUN.num_gpus=1 model.redirect_common_files=false"
```

> `EVALUATION.sigma_shift=5.0` is load-bearing for the **originally released** checkpoints. Upstream changed the action-scheduler shift default to `1.0` and states that reproducing the original numbers needs `5.0`; the newer Optional IDM checkpoint was trained at `1.0` and is evaluated without the override. Copy the value from the section of upstream's README that matches your checkpoint rather than carrying one setting across both.

The Optional IDM checkpoint selects its inference mode at evaluation time, with no retraining:

```
+EVALUATION.action_infer_mode=idm          # imagine the future video, then act
+EVALUATION.action_infer_mode=first_frame  # Fast-WAM: act directly from the current observation
```

Upstream reports 98.55% and 97.75% average success respectively over the full LIBERO benchmark (40 tasks x 50 episodes). That is 2000 episodes; a partial run is not comparable to it. Report the episode count next to any rate you quote.

## Evaluating One Task And Recording Video

`run_libero_manager.py` is a multi-GPU supervisor for the whole 40-task benchmark. For a single task — a smoke test, or a video — call the worker directly. It is a hydra entrypoint on the same `configs/sim_libero.yaml` and runs standalone whenever the `LIBERO_WORKER_*` environment variables the manager sets are absent:

```sh
python experiments/libero/eval_libero_single.py   task=libero_uncond_2cam224_1e-4   ckpt=<checkpoint>.pt   EVALUATION.dataset_stats_path=<stats>.json   EVALUATION.sigma_shift=5.0   EVALUATION.task_suite_name=libero_spatial   EVALUATION.task_id=0   EVALUATION.num_trials=2   model.redirect_common_files=false
```

`eval_libero_single.py` rejects `EVALUATION.env_num` other than `1`; use the manager for parallelism.

**Rollout video is written unconditionally**, one MP4 per trial, named `task<id>_trial<n>` and tagged with the success flag and the task description. It lands under `EVALUATION.output_dir`, which defaults to `./evaluate_results/libero/<task>/<timestamp>` — container-local, so point it at persistent storage for anything you want to keep.

`EVALUATION.visualize_future_video=true` additionally writes the model's *imagined* future frames beside the ground-truth ones, which is what distinguishes a world action model from a plain policy. It requires `model.video_dit_config.action_conditioned=false` and switches inference from `infer_action` to the more expensive `infer_joint`.

## Training


Precompute the T5 embedding cache first, then train. Both steps need the backbone from [Model Preparation](#model-preparation):

```sh
# single GPU
python scripts/precompute_text_embeds.py task=libero_uncond_2cam224_1e-4 model.redirect_common_files=false
# multi-GPU
torchrun --standalone --nproc_per_node=8 scripts/precompute_text_embeds.py task=libero_uncond_2cam224_1e-4 model.redirect_common_files=false

bash scripts/train_zero1.sh 8 task=libero_uncond_2cam224_1e-4
```

> **`precompute_text_embeds.py` does not support LeRobot 3.0 datasets.** It reads `meta/tasks.jsonl`, a LeRobot 2.1 filename, while a v3.0 dataset ships `meta/tasks.parquet`. Pointing it at the released `lerobot_v30/` tree fails with `FileNotFoundError: Missing tasks file: .../meta/tasks.jsonl`, even though `data=libero_2cam_lerobot_v30` is a supported training config and the dataloader reads v3.0 fine. The mismatch is in the precompute script alone.
>
> Skip the cache instead of working around it — upstream documents on-the-fly T5 encoding as supported, at roughly 10% lower training throughput:
>
> ```
> data.train.use_text_embed_cache=false
> ```
>
> Use the precompute step only with the LeRobot 2.1 `tar.gz` datasets.

> **`DIFFSYNTH_MODEL_BASE_PATH` does not relocate the ActionDiT payload.** That variable governs only the Wan2.2 weights the loader *downloads*. `model.action_dit_pretrained_path` is a separate setting whose default, `checkpoints/ActionDiT_linear_interp_Wan22_alphascale_1024hdim.pt`, resolves relative to the working directory — so a run that keeps its backbone on a persistent mount fails at model construction with `FileNotFoundError: 'action_dit_pretrained_path' does not exist: /workspace/fastwam/checkpoints/...`, naming the container path even though the environment variable points elsewhere. Override it explicitly:
>
> ```
> model.action_dit_pretrained_path=/mnt/nfs/<YOUR_USERNAME>/fastwam/checkpoints/ActionDiT_linear_interp_Wan22_alphascale_1024hdim.pt
> ```

The image ships a CUDA `devel` base precisely so the training scripts work: DeepSpeed JIT-compiles its ZeRO ops against `nvcc` on first use, which a `runtime` base cannot do.

> **On 46GB GPUs use `train_zero2.sh`, not `train_zero1.sh`.** ZeRO-1 shards optimizer states only, so every rank still holds the full ~12GB of bf16 gradients for this 6B model. Measured on L40 (44.39GiB usable): two GPUs at `batch_size=1` died inside `optimizer.step()` (`deepspeed/runtime/zero/stage_1_and_2.py`) trying to allocate 11.21GiB, and a single GPU died earlier still, at ZeRO init, allocating 22.43GiB for the fp32 partition. **Batch size does not fix this** — the allocation is the optimizer partition, not activations, so shrinking the batch wastes attempts. `scripts/train_zero2.sh` shards gradients as well and clears it. Upstream trains on 96GB H20s, where ZeRO-1 is comfortable.

> **Pass `--large-shm` to any Run:ai training submission.** The dataloader decodes video in worker processes that pass tensors through `/dev/shm`, which Kubernetes defaults to 64MB. Without it a run reaches the training loop and then dies with `DataLoader worker (pid N) is killed by signal: Bus error. It is possible that dataloader's workers are out of shared memory.` The failure surfaces on an arbitrary rank, and `torch.distributed` reports only a generic `ChildFailedError ... exitcode: 1` for that rank, so it reads like a model or memory fault rather than a container setting. `num_workers=0` also avoids it, at a throughput cost.

Upstream trains LIBERO on a single 8-GPU node and RoboTwin on 64 GPUs. Datasets are separate downloads — [`yuanty/LIBERO-fastwam`](https://huggingface.co/datasets/yuanty/LIBERO-fastwam) (LeRobot 2.1 and 3.0 layouts) and [`yuanty/robotwin2.0-fastwam`](https://huggingface.co/datasets/yuanty/robotwin2.0-fastwam) — and must live on a persistent mount.

> On a task's **first** run, set `pretrained_norm_stats` in the matching `configs/data/*.yaml` to `null`. The run writes `runs/{task_name}/{run_id}/dataset_stats.json`, and later runs should point `pretrained_norm_stats` at that file.

> **A short run saves nothing unless you set `max_steps`.** `configs/task/libero_uncond_2cam224_1e-4.yaml` sets `save_every: 2000`, so a run stopped before step 2000 leaves no checkpoint at all — the wall-clock you spent decides nothing about what survives. The trainer does save unconditionally on reaching `max_steps`, so bound the run by steps rather than by killing it:
>
> ```sh
> bash scripts/train_zero1.sh <n_gpus> task=libero_uncond_2cam224_1e-4 \
>   max_steps=<N> save_every=<N>
> ```
>
> Checkpoints are written to `<output_dir>/checkpoints/weights/<step_tag>.pt`, and `train_zero1.sh` sets `output_dir=./runs/<task>/<run_id>` itself. That `.pt` is the same format `ckpt=` expects at evaluation, so a training checkpoint drops straight into the evaluation command above.


## Verified Locally

Built and exercised on an NVIDIA RTX PRO 6000 Blackwell Max-Q (97GB, driver 580.173.02, `sm_120`), image size 31.8GB:

- **Imports and GPU**: `torch 2.7.1+cu128` reports `cuda_available True` and the Blackwell device; `numpy 2.2.6`, `transformers 4.49.0`, `mujoco 3.3.2`, `robosuite 1.4.0` coexist in one interpreter with `fastwam` and `libero`.
- **LIBERO environment**: `libero_spatial` registers 10 tasks, `OffScreenRenderEnv` constructs task 0 from its BDDL file, and `env.reset()` returns a `(256, 256, 3)` `uint8` `agentview_image` with mean 119.8 and no zero pixels — real EGL-rendered content, not a blank buffer. `env.step()` advances the simulator.
- **Model preparation**: the command in [Model Preparation](#model-preparation) runs to completion on the Hugging Face download path, reporting `Saved ActionDiT backbone payload ... (copied=300, interpolated=520, skipped=4)` and writing a 2.04GB `.pt`. It reloads as a dict of `policy` / `backbone_state_dict` / `meta`. This needed `--memory=44g`; see the note in that section.
- **Checkpoint download**: `huggingface-cli download yuanty/fastwam ...` pulls from the released repository without a token, and the retrieved `libero_uncond_2cam224_dataset_stats.json` parses with the expected `action`, `state`, `num_episodes` and `num_transition` keys.

### Verified on Run:ai

Submitted to a project on the `prod` node pool (NVIDIA L40, 46GB, `sm_89`, driver 580.105.08) as a standard training workload with 1 GPU, 2 CPU cores, 16G CPU memory and `--backoff-limit 0`. Completed, logging:

```
2.7.1+cu128 True NVIDIA L40 10 pick up the black bowl between the plate and the ramekin and place it on the plate
```

That confirms three things the local Blackwell run could not: the `cu128` wheels drive `sm_89`, `from libero.libero.envs import OffScreenRenderEnv` resolves inside a real batch pod, and the build-time `~/.libero/config.yaml` prevents the `EOFError` that a stdin prompt would otherwise cause.

**Model preparation** then ran on the same node pool with 1 GPU, 8 CPU cores and `--cpu-memory-request 48G`, writing to an NFS mount, and completed with the same counts as the local run:

```
[INFO] Saved ActionDiT backbone payload to .../ActionDiT_linear_interp_Wan22_alphascale_1024hdim.pt (copied=300, interpolated=520, skipped=4).
```

Verified from a **separate** workload after the writer pod exited — the writer's own `ls` proves nothing about what survived. The directory holds 34G: the three Wan2.2 DiT shards (9.83 + 10.0 + 0.18GB), `Wan2.2_VAE.pth` (2.82GB), `models_t5_umt5-xxl-enc-bf16.pth` (11.36GB), the umt5-xxl tokenizer, and the 2042025883-byte payload.

> The payload is **byte-identical across the two GPUs**: `sha256 7bd65e19…41445` on both the RTX PRO 6000 Blackwell (`sm_120`) and the L40 (`sm_89`). The bf16 interpolation is deterministic and architecture-independent, so a backbone prepared on one machine can be copied to another rather than regenerated — worth knowing before spending the 34GB download twice.

> **Pass `--shell` to `/run.sh` in a Run:ai command that contains a quoted string.** The Run:ai CLI rewrites `--command`, swapping outer and inner quotes, so `/run.sh "python -c '...'"` is stored as `/run.sh 'python -c "..."'`. Without `--shell`, `/run.sh` word-splits that and Python dies on an unterminated string literal while the workload reports only a generic backoff failure. Check the `Command:` line of `runai ... describe` before waiting on the 11GB pull. The swap flips *every* quote character, at both levels, so you cannot dodge it by choosing the other style — `printf '%s %p\n'` also arrives with its `\n` mangled.

**Training and a paired evaluation** also ran on `prod`: ZeRO-2 on 8 GPUs with `--large-shm`, `batch_size=2`, `max_steps=100`, LeRobot 2.1 `libero_spatial` with a precomputed text-embedding cache. It reached `max_steps reached step=100` and wrote `runs/shorttrain/checkpoints/weights/step_000100.pt`.

Evaluating that 100-step checkpoint against the released one, same task and trial count (`libero_spatial` task 0, 3 trials each):

| Checkpoint | `sigma_shift` | Successes | Episode length |
| --- | --- | --- | --- |
| Released `libero_uncond_2cam224.pt` | 5.0 | **3/3** | 70, 70, 77 frames |
| 100-step `step_000100.pt` | 1.0 | **0/3** | 400, 400, 400 frames |

The episode lengths matter more than the tally. `libero_spatial` caps an episode at 400 steps, so the released checkpoint's 70-77 frame episodes are the success condition terminating early, while the short-trained checkpoint runs to the cap every time. That shape — uniform step-limit timeouts against early terminations through the *same* serving path — is a policy that has not learned the task, not a broken harness. 100 steps at `batch_size=2` on 8 GPUs is ~1600 samples against upstream's 10 epochs, and three episodes is far too few to quote as a rate; treat it as a smoke test of the train-then-evaluate loop, nothing more.

> Evaluate a trained checkpoint against **its own** `runs/<name>/dataset_stats.json`, not the released `*_dataset_stats.json`. The normalization is fitted to the training set, and mixing them degrades the policy silently rather than erroring.

> Match `sigma_shift` to how the checkpoint was trained: `5.0` reproduces the originally released checkpoints, `1.0` is the current default and matches anything trained at this commit.

**Not validated here**: full LIBERO evaluation (2000 episodes across 8 GPUs), training to convergence, and anything RoboTwin. Beyond the 3-trial comparison above, no success rate on this page was measured; the benchmark figures quoted earlier are upstream's.

## Limitations

- **RoboTwin is not installed.** `third_party/RoboTwin` and `experiments/robotwin/` ship with the source, but the RoboTwin platform, its assets, and the `policy/fastwam_policy` symlink are not set up. Follow the [RoboTwin repository](https://github.com/RoboTwin-Platform/RoboTwin) inside a running container if you need it, and create the symlink upstream documents.
- **LIBERO's own `requirements.txt` is deliberately not used.** It pins `numpy==1.22.4` and `transformers==4.21.1` against FastWAM's `numpy==2.2.6` and `transformers==4.49.0`, and FastWAM's evaluation imports both packages into a single process. The image installs only what `libero.libero.envs` and `libero.libero.benchmark` actually import. The dropped pins belong to the `libero.lifelong` training stack, which FastWAM does not use, so `libero.lifelong` is not expected to work here.
- **LIBERO's dataset directory is absent**, and importing the benchmark prints `[Warning]: datasets path ... does not exist!`. That is expected: FastWAM trains from its own Hugging Face LeRobot datasets, not from LIBERO's HDF5 demonstrations.
- `~/.libero/config.yaml` is written at build time. Without it, `import libero.libero` prompts on stdin and a non-interactive workload dies with `EOFError: EOF when reading a line` before any FastWAM code runs. Override `LIBERO_CONFIG_PATH` only if you also provide a config file there.

## Storage And Environment Variables

Container-local data is lost when the workload stops, and every artifact here is large. Point these at a persistent mount such as `/mnt/nfs/<YOUR_USERNAME>`:

| Variable | Purpose |
| --- | --- |
| `DIFFSYNTH_MODEL_BASE_PATH` | Where the Wan2.2 backbone weights are downloaded and read from. Defaults to `/workspace/fastwam/checkpoints` inside the image. Budget ~34GB. |
| `DIFFSYNTH_DOWNLOAD_SOURCE` | `modelscope` (upstream default) or `huggingface`. Use `huggingface` outside China, together with `redirect_common_files=false`. |
| `HF_HOME` | Cache for the released checkpoints and datasets. Each checkpoint is 12.0GB. |
| `LIBERO_CONFIG_PATH` | Directory holding LIBERO's `config.yaml`. Defaults to `~/.libero`, pre-populated in the image. |

Training runs write to `runs/`, evaluation writes to `evaluate_results/`, and both are relative to `/workspace/fastwam`. Mount or symlink them onto persistent storage before a long job:

```sh
mkdir -p /mnt/nfs/<YOUR_USERNAME>/fastwam/{runs,evaluate_results}
ln -sfn /mnt/nfs/<YOUR_USERNAME>/fastwam/runs /workspace/fastwam/runs
ln -sfn /mnt/nfs/<YOUR_USERNAME>/fastwam/evaluate_results /workspace/fastwam/evaluate_results
```

> Containers writing to a mounted host directory produce root-owned files. Reclaim them with
> `docker run --rm -v "$PWD/artifacts/fastwam:/out" j3soon/runai-fastwam:latest chown -R $(id -u):$(id -g) /out`.

For anything beyond the above, follow the [upstream documentation](https://github.com/yuantianyuan01/FastWAM/tree/7faa71108368fbb3b6885649f112af607427a2d4) at the pinned commit.
