# Custom Workloads

Use this path for a user Dockerfile, source tree, Conda environment, Python virtual environment, or local command not already covered by a repository application guide.

## Inventory before editing

Inspect:

- `Dockerfile*`, Compose files, and `.dockerignore`;
- `pyproject.toml`, lock files, `requirements*.txt`, `environment*.yml`, and setup files;
- the training/inference entrypoint and its bounded-test flags;
- CUDA, framework, driver, OS, architecture, compiler, and system-package requirements;
- local datasets, caches, credentials, and large generated files that must not enter the build context;
- input, log, checkpoint, and final-output paths.

Record the exact command that succeeds in the user's local environment. Do not infer success from package installation alone.

Try to reproduce a custom workload locally before its first Run:ai submission. Ask for confirmation before a large download or build, use of credentials, or another meaningful local mutation. If local reproduction is declined or infeasible, preserve that boundary in the launch report.

## Choose a containerization path

### Existing Dockerfile

- Build from the intended context and inspect the resulting image configuration.
- Verify that the image has the command shell or entrypoint used by the submission.
- Pin base images and important dependencies. Prefer an immutable digest for a production launch.
- Resolve an image digest from the remote registry after the relevant push/tag operation. Do not reuse a digest solely because it appears in a local Docker cache; the registry may no longer serve that manifest. Verify the exact remote reference with `docker buildx imagetools inspect`, `docker manifest inspect`, or the registry API, then locally test that same reference before submission.
- Use BuildKit secret or SSH mounts for private dependencies. Ensure secret files are excluded from the build context and absent from image history.
- Ensure code needed at runtime is either copied into the image or mounted from persistent storage at the exact expected path.
- Prefer a reviewed script file over deeply nested `--command` shell quoting. When code is staged on NFS, copy only the required non-secret files, record their hashes, and execute the staged path. Use base64 transport only for small non-secret validation text when no file-transfer path exists; verify it with `echo "<sha256>  <path>" | sha256sum --check --status` instead of inline `awk`/`cut`, use `echo` for fixed ownership markers, and never encode credentials as a workaround.

### Conda environment

- Recreate the environment from `environment.yml` or a lock file inside the image.
- Prefer a CUDA/framework base image compatible with the application, then install Conda/micromamba only if needed.
- Remove host-only prefixes and platform-specific build artifacts. Do not copy the host Conda directory.
- Test imports and the bounded application command in the built image.

### Python venv or package project

- Recreate dependencies from `uv.lock`, a pinned `requirements.txt`, Poetry/PDM lock data, or `pyproject.toml`.
- Do not copy `.venv`; virtual environments contain interpreter paths and native wheels tied to the host.
- For a GPU framework, start from an official framework/NGC image or a compatible CUDA runtime rather than installing an arbitrary CUDA wheel into an unrelated base.
- Use the project's real package manager and frozen dependency mode when available.

### Unspecified local environment

- Inspect the interpreter, OS packages, GPU/framework versions, imports, and local command.
- Create the smallest reproducible dependency declaration instead of blindly preserving the entire machine with an unreviewed `pip freeze`.
- If reproducibility cannot yet be established, run only local diagnostics and prepare a draft image; do not submit a speculative cluster workload.

## Image design checks

- Select an architecture supported by the Run:ai nodes.
- Keep the runtime command non-interactive and ensure stdout/stderr are unbuffered.
- Handle signals and return a nonzero exit code on failure.
- Avoid installing dependencies at workload startup when they can be built into the image.
- Make output paths configurable through arguments or environment variables.
- Do not rely on the container home directory for persistence.
- Add a health/listening check for interactive services.
- Tag the image with a meaningful immutable version. Push it only to a registry the target cluster can access, verify the remote digest, and keep `--image-pull-policy Always` on the Run:ai submission even when using the digest.

The repository's standard `/run.sh` and Omniverse helpers are required for repository-supported images, not for every independent user image. A custom image may use `/bin/bash -lc`, an exec-form entrypoint, or its native launcher when that is the tested contract.

## Container environment surprises

These are properties of the Run:ai pod, not of the image, and they bite after the image pull and application startup are already paid for.

- **`HOME` is `/root` regardless of the image's user.** Every submitted pod gets it, even when the image declares a non-root `USER` with a different home; measured on both `ubuntu:24.04` (`uid=0`) and a `uid=1000` image. Whether that matters depends on the image — one that chowns `/root` to that uid writes there fine, one that leaves it root-owned fails for any application caching under `$HOME` (Omniverse Kit and Isaac Sim do). Settle it in under a minute with `--command -- bash -lc 'id; echo HOME=$HOME; ls -ld $HOME; touch $HOME/.probe'`, then pass `-e HOME=<writable path>` plus a `mkdir` in the same chain, or use `--create-home-dir`.
- **A path hard-coded inside the image can be satisfied by a second `--nfs`.** When code resolves an absolute path such as `/home/<user>/<project>/...`, a non-root container cannot create it (`mkdir: cannot create directory: Permission denied`), and neither a symlink nor an in-container `mkdir` is available. Mount the staged sub-directory straight onto it: `--nfs "server=<SERVER>,path=<EXPORT>/<YOUR_USERNAME>/<project>,mountpath=/home/<user>/<project>,readwrite"`. The server serves sub-paths of the export and the kubelet creates the mount point as root before the container starts, so the code runs unmodified instead of being patched per cluster. Keep the ordinary `/mnt/nfs` mount alongside it, and check `describe --events` in the first minute — a refused sub-path leaves the pod in `ContainerCreating` with `FailedMount` rather than failing loudly.
- **A large image's first pull dominates startup.** The 16GB `j3soon/runai-isaac-lab` image took about 14 minutes from the `Pulling` event to the first application log on a node without it, against 13 seconds on a node with it cached. A workload sitting in `Initializing` for ten-plus minutes is expected on a cold node; confirm with the `Pulling`/`Pulled` events before investigating scheduling.

## Local validation matrix

Run the strongest available checks:

1. Dockerfile parses and the image builds for the target architecture.
2. Image starts with the exact command/entrypoint.
3. Dependency imports and configuration loading succeed.
4. A one-step/one-batch/one-iteration execution succeeds.
5. `nvidia-smi` and a framework GPU allocation succeed inside the container when a local NVIDIA runtime exists.
6. A bind mount at the intended NFS container path remains writable as the selected container user.
7. Expected checkpoints/artifacts exist on the host after container exit.
8. Multi-process or multi-container rendezvous succeeds for distributed workloads.

If the host lacks a GPU, use CPU or dry-run flags only when the application supports them. Do not fake GPU validation by checking only that `nvidia-smi` exists on the host.

## Registry and submission boundary

Before pushing or submitting, establish:

- registry repository and authorization;
- immutable tag or digest;
- Run:ai cluster and explicit project;
- compatible node pool, passed explicitly for every GPU submission;
- workload type and smallest valid resources;
- NFS server/export/container mapping;
- runtime secrets and network exposure;
- exact persistent paths and their ownership.

Pushing an image and submitting a workload are external mutations. They are in scope when the user asked to launch, but do not guess a registry, project, privileged setting, secret source, or storage destination.
