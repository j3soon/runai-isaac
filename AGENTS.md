# Repository Guidelines

## Project Structure & Module Organization
This repository is a documentation-and-assets workspace for running NVIDIA Isaac workloads on Run:ai, with supporting Docker images and shell utilities.

- `docker/`: Dockerfiles and image-specific assets (for example `docker/pytorch-mnist/Dockerfile`, `docker/isaac-sim/`, `docker/isaac-lab/`).
- Keep each Docker-backed application and its guide together under `docker/<name>/` unless an established product layout requires otherwise.
- For products with multiple major model/image variants (for example Cosmos, GR00T), prefer separate versioned folders (for example `docker/<name>-n1/`, `docker/<name>-n1.6/`) and matching versioned application guides.
- `scripts/`: Operational shell scripts, grouped by purpose (`scripts/docker/run.sh`, `scripts/admin/`, `scripts/vpn/`).
- `docs/`: User/developer documentation and screenshots (`docs/assets/`).
- `thirdparty/omnicli/`: Bundled Omniverse CLI binaries used by `/run.sh`.
- `.github/workflows/`: Per-image CI workflows for images built and published by this repository.
- `skills/<name>/SKILL.md`: Repository task guides for agents (`add-runai-application`, `launch-runai-workload`, `run-isaac-lab-benchmark`, `admin-debug-runai-node`), with optional `references/` and `scripts/`. `.agents/skills` and `.claude/skills` are symlinks to this directory, so each harness finds the same files; add and edit skills under `skills/` only.

## Agent Skills and Durable Notes

- A request to "use the skill" for a task refers to `skills/`. Harnesses that load skills automatically reach them through the `.agents/skills` and `.claude/skills` symlinks; otherwise treat them as plain files: locate the task's `SKILL.md`, read it, and follow it alongside this document.
- Development machines here are ephemeral. Record durable findings in the repository, not in an assistant's local memory: reusable pitfalls and their workarounds in the relevant skill's `references/` notes (for example `skills/add-runai-application/references/validation-notes.md`), cluster/node failures in `troubleshooting.md`, image-specific behavior in that image's `docker/<name>/README.md`, and workflow changes in the relevant `SKILL.md`.
- `docs/developer-notes.md` is maintained by humans. Agents must not add, edit, or reorganize entries there, even when a finding would fit its format; put the finding in the skill's `references/` notes instead and let a maintainer promote it if it belongs in the human-facing document. Reading and linking to it is fine.
- Keep such notes environment-agnostic. Use placeholders (`<YOUR_LAB>`, `<NODE_NAME>`, `<YOUR_USERNAME>`) rather than real hostnames, accounts, or tokens.
- Read the relevant skill's `references/` notes **before** starting work, not while debugging a failure. They exist because each entry already cost someone a wrong conclusion, and the cost repeats when they are consulted late. In particular, do not try to screenshot or screen-record a simulator GUI: `x11grab`, `xwd`, and `import` all read an X surface that Isaac Sim's Vulkan swapchain does not present to, so they yield black or empty images no matter how correct the window looks in `xwininfo`. Use the application's own recorder (`--video`, in-app capture); see `skills/add-runai-application/references/validation-notes.md`.

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
- Use explicit version tags for Dockerfile base images without `@sha256` digests, matching the existing repository convention. Record resolved image digests in validation notes or benchmark evidence when needed instead of embedding them in `FROM`.
- For Dockerfiles copied from upstream projects, keep them verbatim by default and include the upstream reference link on the first line. If upstream companion files are needed, prefer a concise self-contained `Dockerfile` that clones the upstream repo at a pinned commit/tag during build. Keep the upstream-verbatim Dockerfile only when practical, and document local fixes briefly in the PR/commit summary.
- Do not use branch names (for example `main`) for upstream refs; always query/find the latest commit SHA over the network and pin that exact commit SHA.
- If a Cosmos image reference is needed, refer to `docker/cosmos3/Dockerfile` for Cosmos 3, or `docker/cosmos-predict2.5/Dockerfile` and `docs/applications/cosmos-predict2.5.md` for earlier generations.
- Cosmos image naming differs by generation: keep legacy v1 image names (for example `j3soon/runai-cosmos-predict1`) for backward compatibility, but use tag-based names for v2/v2.5 images (for example `j3soon/runai-cosmos-predict:2.5`, `j3soon/runai-cosmos-reason:2`) for future images.
- Cosmos 3 unifies the previously separate Predict/Transfer/Reason products into one omnimodal model family, so it uses the family-level image name `j3soon/runai-cosmos:3` with a single `docker/cosmos3/` folder covering both the Reasoner and Generator surfaces. Install it from `NVIDIA/cosmos-framework` (the runnable package) rather than `NVIDIA/cosmos` (docs and cookbooks), and prefer the CUDA 13 groups upstream recommends.
- Application docs must include a `/run.sh` command note (environment command example), and it must match the Dockerfile's environment/tooling (for example use `uv pip install ...` for `uv`-managed images instead of `pip install ...`).
- Dockerfiles should end with the standard `thirdparty/omnicli` and `scripts/docker/run.sh` copies plus `chmod` and CRLF guard (`sed -i 's/\r$//' /run.sh`); also set `ENV SHELL=/bin/bash`.
- If a Dockerfile depends on a pinned upstream commit/tag/sha, keep that pin in the Dockerfile and do not document ad-hoc user overrides in app guides unless the repo explicitly supports/testing that workflow.
- Keep scripts Unix-formatted (LF line endings) and executable when intended.
- A pinned `uv.lock` does not necessarily cover every optional dependency group. Adding one to an existing `uv sync --locked` can fail with "the lockfile at `uv.lock` needs to be updated", which is a lockfile-coverage problem, not a dependency conflict — check `[tool.uv] conflicts` before assuming the latter. Follow whatever upstream's own documentation does for that group; when it syncs unlocked, add the group in a separate unlocked layer so the locked base environment is preserved, and record in a comment which packages the extra layer actually installs.
- This repository is public. Before writing an identifiable name into it (cluster, host, IP, project, or account), survey the existing usage first: `git grep -I -i -c '<term>' -- . ':!artifacts'`. Five or more existing uses means the term is already established and may be reused; fewer than five means ask the user before introducing it. Prefer placeholders (`<YOUR_LAB>`, `<NODE_NAME>`, `<YOUR_USERNAME>`, `<project>`) otherwise. Generic hardware and version facts are exempt.

## Adding Docker-Backed Applications
- Before adding an application, inspect the closest existing Dockerfiles, application guides, image table, application index, and CI workflows. Follow the current repository conventions rather than copying a legacy file mechanically.
- Verify upstream installation instructions and source references from authoritative sources. Record exact image versions, tags, commits, and compatibility constraints instead of relying on moving defaults.
- Present a concise proposed file scope and resolve material questions such as image naming, versioning, workload type, and publishing before implementation.
- A published application normally needs a Dockerfile, an adjacent `README.md`, an entry in the root pre-built image table, an entry in `docs/applications.md`, and a per-image CI workflow when automated publishing is requested.
- Keep image names, tags, build commands, environment commands, and version references consistent across the Dockerfile, guide, indexes, and CI.
- Do not stage, unstage, or otherwise change the Git index unless the user explicitly requests it. Preserve unrelated working-tree changes.

## Testing Guidelines
There is no comprehensive automated test suite in this repo. Validate changes by:

- Building the affected Docker image(s).
- Running a syntax check for modified shell scripts (`bash -n`).
- Performing a targeted manual smoke test for behavior changes (for example admin/vpn script flags).
- For new applications, verify documentation commands against the built image and include reproducible local testing and cleanup steps when practical.

Store run outputs and validation evidence under `artifacts/`, never in `/tmp`:

- `/artifacts/` is gitignored, so evidence stays with the project and survives reboots without risking a commit. Note that a root-level `artifacts_*.zip` is **not** covered by that rule.
- Follow the existing layout `artifacts/<app>/raw/evidence/<version>/<utc-timestamp>/` with lowercase timestamps (for example `20260804t133723z`), plus a short `README.md` recording hardware, image tag, and arguments.
- Containers writing to a mounted host directory produce root-owned files. Reclaim them with a throwaway `docker run --rm -v "$PWD/artifacts/<app>:/out" <image> chown -R $(id -u):$(id -g) /out`; do not reach for `--user`, which breaks venv-based images.

## Commit & Pull Request Guidelines
Recent history uses short, imperative commit subjects such as `Add ...`, `Update ...`, `Upgrade ...`, and `Change ...`. Follow that pattern and keep one logical change per commit.

PRs should include a clear summary, affected paths (for example `docker/isaac-lab/` or `docs/developer-notes.md`), validation steps run, and screenshots when documentation/UI screenshots are changed.
