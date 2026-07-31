---
name: add-runai-application
description: Add a Docker-backed NVIDIA Run:ai sample application in this repository, including its Dockerfile, adjacent application guide, repository indexes, optional image-publishing CI, and validation. Use when creating a new application image, introducing a separately maintained major model/image variant, or turning an upstream container example into a repository-supported Run:ai application.
---

# Add Run:ai Application

Build a complete application integration that follows the repository's current style and preserves upstream provenance. Survey and agree on the shape of the change before editing.

## 1. Establish the constraints

- Read every applicable `AGENTS.md`, starting at the repository root.
- Record `git status --short` and the staged file set. Never stage or unstage files unless explicitly requested.
- Extract the requested application, version, upstream reference, image repository/tag, Run:ai workload type, publishing scope, and required validation.
- Identify missing choices that materially affect the result. Do not guess an image naming or versioning scheme that conflicts with an existing product family.

## 2. Survey before implementation

- Inspect the closest application folders, their Dockerfiles and READMEs, the root pre-built image table, `docs/applications.md`, and relevant workflows under `.github/workflows/`.
- Prefer recent analogues with the same workload type, dependency manager, upstream layout, and image-version strategy.
- Inspect authoritative upstream documentation and source over the network. Resolve moving branches or tags to the exact commit required by repository policy.
- Check upstream licenses, base-image requirements, architectures, entrypoints, companion files, and known runtime constraints.
- When matching an existing published image, verify the tag-to-commit relationship and digest when possible.
- Report the selected analogues, upstream revision, proposed files, validation approach, and concise questions. Wait for approval before editing when the user requests a survey or plan first.

## 3. Design the application boundary

- Use a dedicated `docker/<application>/` folder with an adjacent `README.md`.
- Use separate folders for independently maintained major model or image variants; use version-suffixed Dockerfiles only when versions share one application guide and lifecycle.
- Keep the Docker build context at the repository root so shared `thirdparty/omnicli` and `scripts/docker/run.sh` assets remain available.
- Limit the change to the requested application. Add publishing CI only when publishing is requested or clearly established for that image family.

## 4. Create the Dockerfile

- Apply the general Dockerfile requirements from `AGENTS.md`.
- Put the pinned upstream browser permalink in the first comment. Explain briefly why that revision is pinned.
- Preserve a practical upstream Dockerfile verbatim. If it requires an unavailable source tree, create a concise self-contained adaptation that clones and checks out the exact commit.
- Fetch small upstream companion files directly from pinned raw GitHub URLs and pair them with readable pinned source-permalink comments. Clone larger source trees at an exact commit.
- Preserve upstream license headers and document repository-specific adaptations next to the changed instruction.
- Avoid build arguments that silently permit moving upstream refs unless the repository explicitly supports and tests that workflow.
- Use the application's real dependency manager and runtime entrypoint. Do not add packages at workload startup when they belong in the image.

## 5. Write the application guide

- Match the closest current README structure and link back to the root setup guide.
- Provide exact root-context build and push commands using the agreed image name and tag.
- Document the Run:ai environment, workload architecture/type, compute resource, storage, command, arguments, and lifecycle needed by this image.
- Include a `/run.sh` environment-command note that matches the installed tools and dependency manager.
- Explain persistent input, checkpoint, and output paths when container-local data would be lost.
- Include reproducible local smoke testing and cleanup instructions when practical. State clearly what local simulation does not validate for distributed or controller-managed workloads.
- Cite authoritative versioned upstream documentation. Do not advertise unsupported ref overrides.

## 6. Integrate repository discovery and publishing

- Add the image and guide to the root pre-built image table when the image is published for users.
- Add the guide to `docs/applications.md`.
- When CI publishing is in scope, copy the closest current per-image workflow and adjust its name, path filters, Dockerfile, and Docker Hub repository consistently. Retain shared-asset path triggers.
- Do not upgrade unrelated workflow actions or reformat neighboring entries as part of the application addition.

## 7. Validate and hand off

- Build the exact Dockerfile from the repository root with its documented tag.
- Run a targeted container smoke test that exercises the real entrypoint or documented command. For distributed images, test rendezvous and rank behavior with multiple containers when feasible.
- Syntax-check changed shell scripts and preserve LF/executable state.
- Verify image names, tags, versions, paths, links, source pins, and commands across every touched file.
- Compare the final staged file set with the initial snapshot and leave it unchanged.
- Report the affected files, exact validation commands and results, any unvalidated external behavior, and notable upstream adaptations. Never claim a build or runtime path was validated when it was not.
