# Ref: https://github.com/NVIDIA/cosmos-framework/blob/ee58e41467f33c49ddde08b4d0ef4923876a95ac/Dockerfile
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: OpenMDW-1.1

# Dockerfile using uv environment.

# The upstream Dockerfile installs from bind-mounted source files (`uv.lock`, `pyproject.toml`,
# `packages`, `.python-version`), which are unavailable when building from this repository root.
# This is a self-contained variant that clones the upstream repo at a pinned commit instead.

ARG CUDA_VERSION=13.0.2
ARG BASE_IMAGE=nvidia/cuda:${CUDA_VERSION}-cudnn-devel-ubuntu24.04
FROM ${BASE_IMAGE}
ARG CUDA_VERSION

# Set the DEBIAN_FRONTEND environment variable to avoid interactive prompts during apt operations.
ENV DEBIAN_FRONTEND=noninteractive

# Install packages
RUN --mount=type=cache,target=/var/cache/apt \
    --mount=type=cache,target=/var/lib/apt \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        curl \
        ffmpeg \
        git \
        git-lfs \
        tree \
        wget

# Install uv: https://docs.astral.sh/uv/getting-started/installation/
# https://github.com/astral-sh/uv-docker-example/blob/main/Dockerfile
# Local fix: upstream pins uv 0.11.28 here, but the `uv.lock` at the pinned commit was regenerated
# with uv 0.12.x, so `uv sync --locked` fails with 0.11.28. Use 0.12.1, which accepts the lockfile.
COPY --from=ghcr.io/astral-sh/uv:0.12.1 /uv /uvx /usr/local/bin/
# Copy from the cache instead of linking since it's a mounted volume
ENV UV_LINK_MODE=copy
# Cache python downloads
ENV UV_PYTHON_CACHE_DIR=/root/.cache/uv/python
# Ensure installed tools can be executed out of the box
ENV UV_TOOL_BIN_DIR=/usr/local/bin

# Install just: https://just.systems/man/en/pre-built-binaries.html
RUN curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --to /usr/local/bin --tag 1.46.0

ENV PATH="/root/.local/bin:$PATH"

WORKDIR /workspace

ARG COSMOS_FRAMEWORK_REPO=https://github.com/NVIDIA/cosmos-framework.git
ARG COSMOS_FRAMEWORK_REF=ee58e41467f33c49ddde08b4d0ef4923876a95ac
RUN git clone ${COSMOS_FRAMEWORK_REPO} /workspace && \
    cd /workspace && \
    git checkout ${COSMOS_FRAMEWORK_REF}

# Install python
RUN --mount=type=cache,target=/root/.cache/uv \
    uv python install

# Install into virtual environment
# Local fix: upstream syncs `--group=cu130 --group=vllm`, but at the pinned commit `vllm` is declared
# mutually exclusive with every `cu*` group in `[tool.uv] conflicts`, so that pair cannot resolve.
# Use the `*-train` group documented in the upstream setup guide, which includes the `cu*` group and
# covers both inference and post-training. vLLM serving uses the separate `vllm/vllm-omni:cosmos3`
# container upstream publishes for that purpose.
RUN echo "$CUDA_VERSION" | sed -E 's/^([0-9]+)\.([0-9]+).*/cu\1\2-train/' > /root/.cuda-name
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked --no-install-project --no-editable --all-extras --group=$(cat /root/.cuda-name)
ENV PATH="/workspace/.venv/bin:$PATH"

# Triton bundled ptxas doesn't support latest GPU architectures
ENV TRITON_PTXAS_PATH="/usr/local/cuda/bin/ptxas"
ENV SHELL=/bin/bash

# Tools and scripts for Omniverse
COPY thirdparty/omnicli /omnicli
COPY scripts/docker/run.sh /run.sh

# Prevent users from accidentally removing the executable permission.
RUN chmod +x /omnicli/omnicli && chmod +x /run.sh
# Prevent users from accidentally saving script files with Windows line endings.
RUN sed -i 's/\r$//' /run.sh

ENTRYPOINT ["/workspace/docker/entrypoint.sh"]

CMD ["/bin/bash"]
