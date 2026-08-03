---
name: launch-runai-workload
description: Validate, package, submit, monitor, and verify user workloads on NVIDIA Run:ai. Use for user-facing runai-isaac repository applications such as PyTorch MNIST, Isaac Lab, Isaac Sim, Cosmos, GR00T, or LeRobot; custom Dockerfile, Conda, virtual-environment, or source-tree workloads; and user-scoped CLI, project, GPU, image, NFS, log, checkpoint, or artifact readiness. Do not use for cluster-node isolation, dev-pool administration, or exact-host GPU or NVLink diagnostics.
---

# Launch Run:ai Workload

Take a workload from local evidence to a verified Run:ai execution. Prefer a finite training workload over an interactive workspace, request the smallest suitable resources, and treat storage verification as a launch gate.

Keep this skill user-scoped. Do not relabel cluster nodes, use the administrator `dev` pool, or launch exact-host node diagnostics. For an explicitly authorized node-administration request, use the `admin-debug-runai-node` skill instead.

## 1. Establish the workload contract

- Read applicable repository instructions and record `git status --short` before editing a user project. Never change the Git index unless requested.
- Determine whether the target is a repository example or a custom workload.
- Establish the cluster, explicit project, compatible node pool, workload name, image, workload type, command, GPU count, CPU/memory needs, expected duration, and cleanup policy.
- Prefix names with the Run:ai username. Add a short unique suffix for validation runs.
- Identify inputs, logs, checkpoints, and final artifacts. Classify every path as persistent or ephemeral.
- Discover missing values from local documentation and CLI context before asking the user. Ask only when a material choice cannot be inferred safely.

For a repository example, read [references/examples.md](references/examples.md). For a custom image or local environment, read [references/custom-workloads.md](references/custom-workloads.md). Before any submission, read [references/runai-cli.md](references/runai-cli.md).

## 2. Run a non-mutating preflight

Run:

```bash
<skill-dir>/scripts/preflight.sh --project <project> [--local-output-dir <path>] [--require-docker] [--require-gpu]
```

An `SSL_CERT_FILE` export made by the preflight is process-local. If it reports the installed Run:ai CA, export that same path in the invoking shell before later `runai` commands.

When the workload needs NFS, resolve the approved asset without exposing credentials:

```bash
<skill-dir>/scripts/discover-nfs.sh --project <project> [--name <asset-name>]
```

Treat values in `secrets/env.sh` as local hints, not the authoritative NFS mapping. Reject unresolved placeholders, and prefer the current Run:ai data-source server/export when the env file disagrees.

Resolve failures in this order:

1. VPN or cluster reachability, when required.
2. TLS trust and `runai` authentication.
3. Explicit project access; never rely only on a stale default project.
4. Docker daemon access and registry access.
5. Host GPU, driver, and NVIDIA container runtime when GPU-local validation is required.
6. NFS server, export path, container mount path, username subdirectory, and write permissions.

Use the installed CLI's `--help` output as the command contract. Adapt reference commands when the installed version differs.

## 3. Select the execution path

### Repository example

- Use the published image and command from the closest current application guide.
- Do not pull, build, or run a repository-provided application image locally unless the user explicitly requests local validation. Use the repository's documented image contract, then validate the submitted workload on Run:ai.
- Use a standard training workload for a finite command, even if an older guide demonstrates it through a workspace.
- Use a workspace only for an interactive service such as Jupyter, VSCode, noVNC, or SSH.
- Use a framework workload for actual multi-pod distributed execution. When local validation is explicitly requested, reproduce it with multiple containers when practical.

### Custom workload

- Try to reproduce the user's custom workload locally before its first cluster submission. Ask for confirmation first when reproduction requires a large download or build, credentials, or another meaningful local mutation; report the resulting validation gap if the user declines.
- If a Dockerfile exists, inspect its base image, architecture, entrypoint, dependency pins, build context, secrets, and output paths before building.
- If only Conda, venv, Python lock files, or a local environment exists, create a reproducible image from the declared dependencies. Do not copy a host virtual environment into an image.
- A Run:ai submission always needs a cluster-accessible container image. A local environment without an image can only be tested locally until it is containerized and pushed to an accessible registry.
- Do not put credentials, tokens, private keys, or user data in image layers. Use runtime secrets or approved Run:ai credentials.

## 4. Prove the storage contract

Before the first real submission, state all of the following and obtain explicit user confirmation:

- the container paths for inputs, logs, checkpoints, and final artifacts;
- which paths persist after the pod exits;
- how Run:ai logs will be retrieved;
- what is intentionally ephemeral;
- the NFS server/export or approved data-source mapping.

Run:ai stdout/stderr logs are useful operational evidence but are not a durable artifact contract. When logs must survive workload deletion or control-plane retention, configure the application to write log files below the confirmed NFS user directory and verify them like checkpoints.

For this repository's cluster convention, NFS is mounted at `/mnt/nfs`, and user-owned data belongs under `/mnt/nfs/<username>`. Do not assume the lab export or username; derive and verify them.

For custom workloads, when Docker is available, validate the exact container mount path. Skip this local image test for repository-provided applications unless the user explicitly requests it:

```bash
<skill-dir>/scripts/validate-local-mount.sh \
  --image <image> \
  --host-dir <local-directory> \
  --container-dir /mnt/nfs/<username> \
  [--gpu auto|required|disabled] \
  [--command '<one-step smoke command>']
```

On Run:ai, write a uniquely named probe below `/mnt/nfs/<username>/.runai-probes/`, let the pod exit, then verify the same file independently through a later workload, FTP, or authorized SSH. Reading it only inside the writer pod is insufficient. Remove only the probe created for the test after verification.

## 5. Validate custom workloads locally in proportion to capability

- Apply this section to custom workloads. For repository-provided applications, skip local image pulls, builds, and runtime tests unless the user explicitly asks for them.
- Build or pull the exact image that will be submitted.
- If Docker and the NVIDIA runtime are usable, run the real entrypoint or command with `--gpus all` and execute one training step, one short epoch, or an equivalent bounded test.
- Mount a local directory at the exact future NFS container path. Confirm expected logs/checkpoints/artifacts appear on the host after the container exits.
- For distributed training, launch at least two containers with separate ranks on one Docker network when feasible.
- If no GPU or NVIDIA runtime exists, still validate the Docker build, command/entrypoint, dependency import, CPU fallback, configuration parsing, and submission command. Report the untested GPU behavior precisely.
- Use a dedicated `mktemp -d` bind-mount root. If the container creates root-owned validation outputs, remove only the known test subtree through an isolated container with the same mount, then remove the empty host directory; do not use host `sudo` or broaden ownership.
- Do not turn a smoke test into a full training run. Apply explicit time/iteration limits and clean up only the containers, networks, volumes, and probe files created for validation.

## 6. Submit with bounded resources

- Show the exact resolved submission command before executing it.
- Pass `--project` explicitly and start with one GPU unless the example inherently requires more.
- Resolve a GPU-capable node pool from cluster documentation or successful project workloads and pass it explicitly on every GPU submission. Treat omission as a blocking error; the CLI default may be CPU-only. On this repository's configured cluster, pass `--node-pools prod` for user workloads.
- Include `--image-pull-policy Always` in every Run:ai CLI submission, including immutable digests, validation readers, workspaces, and distributed jobs. Treat omission as a blocking command-validation error.
- For custom writer and verifier logic, treat inline wrappers containing backslash escapes, `awk`/`cut`, or quoted `python -c` as blocking command-validation errors. Stage reviewed non-secret scripts and hash-check them instead; a request for a compact one-liner does not override this guard.
- Prefer immutable tags or remotely verified digests for custom production workloads. Do not trust a local cache's recorded repository digest without checking that the registry still serves it.
- Set a zero retry/backoff limit for validation so deterministic failures are visible quickly.
- Mount persistent storage in every pod that writes or reads shared state, including distributed masters unless intentionally excluded.
- Do not enable privileged mode, host networking, host paths, broad capabilities, or unauthenticated public endpoints without explicit need and user authorization.
- Keep completed validation workloads until logs, events, exit state, and storage are verified. Do not enable automatic deletion before evidence is collected.

## 7. Monitor and verify the result

- Poll status with bounded intervals. Inspect `describe` events while pending or initializing.
- Capture logs from every pod/rank for distributed workloads, not only the first pod.
- Confirm the expected completion state and meaningful application evidence such as a loss/accuracy line, completed iteration, listening service, or successful artifact write.
- Verify persistent outputs independently after the writer container has exited.
- On failure, inspect events first, then logs and runtime state. Distinguish authentication, scheduling, image pull, command/entrypoint, GPU compatibility, out-of-memory, distributed rendezvous, NFS mount, and file-permission failures.
- Fix the smallest confirmed cause, rerun the narrow validation, and only then launch the intended workload.

## 8. Clean up and report

- Delete temporary validation workloads after evidence is captured unless the user asks to retain them. Never delete the user's real workload merely because verification is complete.
- Remove only validation artifacts created by this run. Preserve user checkpoints and logs.
- Report the image reference, project, workload name/type, resources, exact persistent paths, local checks, Run:ai final state, key log evidence, artifact verification method, and anything not validated.
