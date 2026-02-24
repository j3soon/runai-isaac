# Repository Guidelines

## Project Structure & Module Organization
This repository is a documentation-and-assets workspace for running NVIDIA Isaac workloads on Run:ai, with supporting Docker images and shell utilities.

- `docker/`: Dockerfiles and image-specific assets (for example `docker/pytorch-mnist/Dockerfile`, `docker/isaac-sim/`, `docker/isaac-lab/`).
- `scripts/`: Operational shell scripts, grouped by purpose (`scripts/docker/run.sh`, `scripts/admin/`, `scripts/vpn/`).
- `docs/`: User/developer documentation and screenshots (`docs/assets/`).
- `thirdparty/omnicli/`: Bundled Omniverse CLI binaries used by `/run.sh`.
- `.github/workflows/`: CI workflow(s), currently building/publishing the `runai-pytorch-mnist` image.

## Build, Test, and Development Commands
- `docker build -t local/runai-pytorch-mnist -f docker/pytorch-mnist/Dockerfile .`: Build the example training image locally.
- `bash scripts/docker/run.sh "echo hello"`: Smoke-test the helper entrypoint script behavior.
- `bash -n scripts/docker/run.sh` (and other `scripts/**/*.sh`): Shell syntax check before submitting changes.
- `chmod +x scripts/<path>.sh`: Restore executable bit if a script was edited on Windows or copied incorrectly.

Use `README.md` and `install.md` for end-to-end setup and cluster-specific steps.

## Coding Style & Naming Conventions
- Shell scripts use Bash (`#!/bin/bash`) with 2-space to 4-space indentation; keep style consistent with the touched file.
- Prefer descriptive, lowercase file names with underscores for scripts (for example `create_user.sh`).
- Dockerfiles are organized by product/version (`Dockerfile_5_0_0`, `Dockerfile_2_2_0`); follow the existing version suffix format.
- For Dockerfiles copied from upstream projects, keep them verbatim by default and include the upstream reference link on the first line. If upstream companion files are needed, prefer a concise self-contained `Dockerfile` that clones the upstream repo at a pinned commit/tag during build. Keep the upstream-verbatim Dockerfile only when practical, and document local fixes briefly in the PR/commit summary.
- Do not use branch names (for example `main`) for upstream refs; always query/find the latest commit SHA over the network and pin that exact commit SHA.
- If a Cosmos image reference is needed, refer to `docker/cosmos-predict2.5/Dockerfile` and `docs/applications/cosmos-predict2.5.md`.
- Application docs must include a `/run.sh` command note (environment command example), and it must match the Dockerfile's environment/tooling (for example use `uv pip install ...` for `uv`-managed images instead of `pip install ...`).
- Dockerfiles should end with the standard `thirdparty/omnicli` and `scripts/docker/run.sh` copies plus `chmod` and CRLF guard (`sed -i 's/\r$//' /run.sh`); also set `ENV SHELL=/bin/bash`.
- Keep scripts Unix-formatted (LF line endings) and executable when intended.

## Testing Guidelines
There is no comprehensive automated test suite in this repo. Validate changes by:

- Building the affected Docker image(s).
- Running a syntax check for modified shell scripts (`bash -n`).
- Performing a targeted manual smoke test for behavior changes (for example admin/vpn script flags).

## Commit & Pull Request Guidelines
Recent history uses short, imperative commit subjects such as `Add ...`, `Update ...`, `Upgrade ...`, and `Change ...`. Follow that pattern and keep one logical change per commit.

PRs should include a clear summary, affected paths (for example `docker/isaac-lab/` or `docs/developer-notes.md`), validation steps run, and screenshots when documentation/UI screenshots are changed.
