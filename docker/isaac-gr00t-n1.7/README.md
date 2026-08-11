# Isaac GR00T N1.7

This page is part of the sample applications guide. Follow [README](../../README.md) first and stop interactive workloads when finished.

(Optional) Create a docker image for [Isaac GR00T](https://github.com/NVIDIA/Isaac-GR00T) (N1.7) following the [installation guide](https://github.com/NVIDIA/Isaac-GR00T):

```sh
docker build -f docker/isaac-gr00t-n1.7/Dockerfile . -t j3soon/runai-isaac-gr00t:n1.7
docker push j3soon/runai-isaac-gr00t:n1.7
```

> `docker/isaac-gr00t-n1.7/Dockerfile` is a self-contained variant of the upstream [`docker/Dockerfile`](https://github.com/NVIDIA/Isaac-GR00T/tree/main/docker). It clones the upstream repo during the build because this repository does not vendor the source, and it installs the project so `gr00t` imports without a `PYTHONPATH` setting (upstream ships the venv only). N1.7 uses a different stack from the [N1.6](../isaac-gr00t-n1.6/README.md) image, so it gets its own folder.

> **The pin is the upstream commit whose subject is `GR00T N1.7 General Release` (`1a1837f2`, 2026-07-07), which carries no git tag.** It is deliberately not the `n1.7-release` tag (`23ace64f`, 2026-04-18, subject `GR00T N1.7 Release`), an earlier N1.7 build that upstream superseded without moving or adding a tag. The tagged build serializes with plain `msgpack` and cannot serve a [RoboLab](../robolab/README.md) client, which sends `msgpack_numpy`-encoded arrays; the General Release added that support. If you pin by tag expecting the newest N1.7, you will get the older one.

> The `nvidia/GR00T-N1.7-DROID` checkpoint is public, but it loads the **gated** [`nvidia/Cosmos-Reason2-2B`](https://huggingface.co/nvidia/Cosmos-Reason2-2B) backbone. Accept that license and pass `HF_TOKEN` to the container, or the server fails with `401 ... You are trying to access a gated repo`. A pre-populated Hugging Face cache is not enough: the loader still resolves the repo through the Hub API, and `HF_HUB_OFFLINE=1` turns that into a hard failure instead of a cache hit.

> Environment command:
>
> ```
> /run.sh "python gr00t/eval/run_gr00t_server.py --model-path nvidia/GR00T-N1.7-DROID --embodiment-tag OXE_DROID_RELATIVE_EEF_RELATIVE_JOINT --device cuda --host 0.0.0.0 --port 5555 --use-sim-policy-wrapper"
> ```
>
> The image sets `PYTHONUNBUFFERED=1`, without which the server's readiness banner stays buffered and a healthy server looks hung at `Loading checkpoint shards`. Upstream's own image builds the virtual environment without the project, so callers there must bind-mount the source and set `PYTHONPATH`; this image installs the project instead, so `gr00t` imports directly.

## Serve A Policy

Start the policy server. It reports `Server is ready and listening on tcp://<host>:5555` once the checkpoint is loaded:

```sh
docker run --rm --gpus all --network=host --ipc=host \
  -e HF_TOKEN="$HF_TOKEN" \
  -v ~/.cache/huggingface:/root/.cache/huggingface \
  j3soon/runai-isaac-gr00t:n1.7 \
  python gr00t/eval/run_gr00t_server.py \
    --model-path nvidia/GR00T-N1.7-DROID \
    --embodiment-tag OXE_DROID_RELATIVE_EEF_RELATIVE_JOINT \
    --device cuda --host 127.0.0.1 --port 5555 --use-sim-policy-wrapper
```

Clients connect over ZMQ with `gr00t.policy.server_client.PolicyClient`, which exposes `ping()`, `get_modality_config()`, and `get_action()`. `get_action` returns an `(action, info)` tuple on this revision.

For the DROID embodiment the server expects `video.exterior_image_1_left` and `video.wrist_image_left` as `(B, T, H, W, C)` `uint8`, `state.eef_9d` `(B, T, 9)`, `state.joint_position` `(B, T, 7)`, `state.gripper_position` `(B, T, 1)`, and `annotation.language.language_instruction` as a list of strings. It returns 40-step action chunks: `action.joint_position` `(B, 40, 7)`, `action.eef_9d` `(B, 40, 9)`, and `action.gripper_position` `(B, 40, 1)`.

> `state.eef_9d` is a position plus a 6D rotation. Passing zeros is degenerate and the server fails with `SVD did not converge` while orthonormalizing it, so send a valid rotation.

For measured latency, VRAM, and the RoboLab loop figures, see the
[performance guide](./performance.md).

Two rules when measuring here:

- **Let the GPU warm up.** The first calls after the server reports ready are several times slower while clocks ramp from idle. Discard at least the first ten calls.
- **Image content changes the cost.** Synthetic all-zero frames are the cheapest case and understate real camera input substantially. Benchmark with representative frames rather than `np.zeros`.

## Evaluate With RoboLab

This image serves [RoboLab](../robolab/README.md)'s GR00T client. Start the server as above with `--network=host`, then run the client from the RoboLab image:

```sh
docker run --rm --gpus all --network=host --ipc=host \
  -e OMNI_KIT_ACCEPT_EULA=Y -e ACCEPT_EULA=Y \
  -v "$(pwd)/artifacts/robolab/out:/workspace/robolab/output" \
  --entrypoint bash j3soon/runai-robolab:0.3.0 -c \
  'cd /workspace/robolab && /workspace/isaaclab/_isaac_sim/python.sh -u policies/gr00t/run.py \
     --headless --task BananaInBowlTask --num-envs 1 \
     --remote-host 127.0.0.1 --remote-port 5555 --open-loop-horizon 8'
```

Verified end to end: `BananaInBowlTask` completes successfully through this path. Read per-run figures from the `timing` block RoboLab writes into `episode_results.jsonl`; the simulator step, not policy inference, dominates. `--open-loop-horizon 8` reuses each 40-step action chunk across 8 environment steps, so the per-step inference cost is far below the standalone latency.

> This works only because of the pin. The `n1.7-release` tag cannot serve this client at all; see the pin note near the top.

## Limitations

- The LFS-tracked `demo_data/` and `media/` are checked out as pointer files, not real content, to keep the image small. Scripts that read a bundled dataset (for example `scripts/deployment/standalone_inference_script.py --dataset-path demo_data/...`) need `git lfs pull` inside the container first. The aarch64 wheel pointers under `scripts/deployment/*/wheels/` are unused on x86_64.

## Storage And Environment Variables

Container-local data is lost when the workload stops. Point these at a persistent mount such as `/mnt/nfs/<YOUR_USERNAME>`:

| Variable | Purpose |
| --- | --- |
| `HF_TOKEN` | Hugging Face token for the gated `Cosmos-Reason2-2B` backbone. Required. |
| `HF_HOME` | Cache directory for checkpoints. The DROID checkpoint is about 6.5GB and the backbone about 4.6GB. |

For finetuning and the other evaluation harnesses, follow the [upstream documentation](https://github.com/NVIDIA/Isaac-GR00T/tree/1a1837f20538b7d7e21f977a11a5aee14f99803c) at the pinned commit.
