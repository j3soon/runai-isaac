# Repository Examples

Use this catalog for the common examples, then inspect the referenced guide in the current `runai-isaac` checkout before submission. The root `README.md` pre-built image table and `docs/applications.md` are the source of truth for additional applications and current published tags.

## Selection rules

- Names ending in `-ex` are interactive images intended for workspaces with tools. Non-`-ex` images are the default for finite headless jobs.
- Use the latest explicitly documented version unless the user names a version or compatibility requires an older one. Never invent a tag.
- Prefer `runai training standard submit` for finite single-pod tests, `runai workspace submit` for interactive services, and `runai training pytorch submit` for multi-pod PyTorch.
- Read the image guide for its `/run.sh` command, security/user setting, required ports, shared-memory needs, and persistent-output notes.
- Do not pull, build, or run repository-provided application images locally unless the user explicitly requests local validation. Validate them through bounded Run:ai execution instead.

## PyTorch MNIST

- Guide: root `README.md`, section `Jupyter Lab with Custom Base Image`.
- Image: `j3soon/runai-pytorch-mnist`.
- Interactive mode: workspace with Jupyter.
- Batch mode: standard training workload running:

  ```bash
  /run.sh "cd /mnt/nfs/<username>/mnist" "python main.py --save-model --epochs 1"
  ```

- Inputs: `/mnt/nfs/<username>/mnist` and `/mnt/nfs/<username>/data` prepared according to the guide.
- Persistent checkpoint: `/mnt/nfs/<username>/mnist/mnist_cnn.pt`.
- Do not claim the example is ready merely because the base image starts; validate that the code/data paths exist and the checkpoint appears after container exit.

## PyTorch Distributed MNIST

- Guide: `docker/pytorch-mnist-dist/README.md`.
- Image: `j3soon/runai-pytorch-dist-mnist`.
- When local validation is explicitly requested, use the documented two-container CPU/Gloo procedure or an equivalent two-rank GPU test.
- Cluster mode: PyTorch training with one master plus one worker for the smallest distributed test. Request one GPU for the master and one for the worker.
- The image entrypoint already runs `/opt/mnist/src/mnist.py`. Prefer passing bounded arguments such as `--epochs 1` rather than overriding it. The PyTorch operator supplies rank and rendezvous environment variables.
- A tested CLI `2.23` submission is:

  ```bash
  runai training pytorch submit <name> \
    --project <project> \
    --image j3soon/runai-pytorch-dist-mnist \
    --image-pull-policy Always \
    --node-pools prod \
    --workers 1 \
    --gpu-devices-request 1 \
    --master-gpu-devices-request 1 \
    --large-shm \
    --backoff-limit 0 \
    --restart-policy Never \
    --master-restart-policy Never \
    -- --epochs 1 --batch-size 1024 --test-batch-size 5000
  ```

- The first pull of this large image can take several minutes. While it is healthy, `describe` shows both pods scheduled with image-pull events; do not misdiagnose that as a rendezvous failure.
- Capture logs from both pods and require distinct rank/world-size messages plus an accuracy result.
- Keep the default `gloo` backend. The upstream script uses `torch.device("cuda")` with no `LOCAL_RANK` mapping, so every local rank shares GPU 0 and `nccl` cannot run. This validates rendezvous and DDP, not GPU scaling.
- Its `accuracy=` divides by the full test set while each rank samples `1/world_size` of it, so a bounded run reports roughly `0.1/world_size`. That is the expected metric artifact, not a failure.
- This sample produces logs but no durable model checkpoint by default. Confirm that this is acceptable or adapt the script/output path before a real run.

## Isaac Lab headless

- Guide: `docker/isaac-lab/README.md`.
- Image: use the version documented for the workload. For the full performance
  matrix or distributed Camera, use `j3soon/runai-isaac-lab:2.2.0`; the tested
  2.3.2 renderer rejects nonzero local GPU ranks. Use the
  `run-isaac-lab-benchmark` skill for benchmark runs.
- Mode: standard training for finite headless jobs.
- Baseline command:

  ```bash
  /run.sh "/workspace/isaaclab/isaaclab.sh -p -u scripts/reinforcement_learning/rl_games/train.py --task=Isaac-Cartpole-v0 --headless"
  ```

- For the documented RL-Games Cartpole task on image `2.3.2`, a tested bounded suffix is `--num_envs 512 --max_iterations 1`. Its configured horizon is `16` and minibatch size is `8192`, so smaller environment counts such as `16` or `64` fail the RL-Games divisibility assertion. Re-check the selected task/image configuration instead of assuming `512` applies to every task or release.
- Request one GPU and large shared memory. The repository image accepts the NVIDIA Isaac EULA through its image configuration.
- Default training logs/checkpoints under the image workspace are ephemeral. For a real workload, use a code/config-supported log directory below `/mnt/nfs/<username>` or copy final outputs there before exit, then verify them independently.
- For multi-node execution, follow the guide's distributed section and let the Run:ai PyTorch operator provide rendezvous values. Do not hard-code node count, rank, or master address unless the selected integration explicitly requires it.

## Isaac Lab Extended

- Guide: `docker/isaac-lab-ex/README.md`.
- Image: `j3soon/runai-isaac-lab-ex:2.3.2` unless another documented version is selected.
- Mode: interactive workspace with one GPU and large shared memory.
- Command:

  ```bash
  /run.sh "/usr/bin/supervisord -n"
  ```

- Expose only needed tools: VSCode on container port `8080` and noVNC on `6080`. Apply the cluster's authentication policy; do not expose an unauthenticated public endpoint.
- Use the image user/group source required by the guide (`fromTheImage` on current versions).
- Store code and all durable data below `/mnt/nfs/<username>`.
- For automated validation, override the service command with the bounded Isaac Lab headless test rather than leaving an interactive workspace idle.

## Other repository applications

1. Find the image and guide in the root pre-built image table.
2. Read its adjacent `docker/<application>/README.md` and Dockerfile.
3. Classify it as headless finite, interactive `-ex`, or distributed.
4. Extract the exact image tag, `/run.sh` command, ports, GPU/shared-memory requirements, dependency manager, and persistence notes.
5. Skip local image validation unless the user explicitly requests it; use a smaller Run:ai validation job before launching the user's full command.

Do not mechanically reuse an Isaac Lab command for Isaac Sim, Cosmos, GR00T, LeRobot, or NVHPC. Their entrypoints, dependency managers, licenses, model downloads, credentials, and resource requirements differ.
