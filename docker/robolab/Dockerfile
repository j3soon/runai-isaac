# Ref: https://github.com/NVlabs/RoboLab/blob/f72d39445ab699c9cfd9bf551e8d21b6075293b9/docker/Dockerfile
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# The upstream Dockerfile builds from the RoboLab working tree (`COPY . /workspace/robolab` plus
# per-directory `assets/` layers), which is unavailable when building from this repository root.
# This is a self-contained variant that clones the upstream repo at a pinned commit instead.
# The commit is the `v0.3.0` release tag, the latest RoboLab release.

# The IsaacLab/IsaacSim stack is selected by the base image tag. This image pins upstream's default
# `isaac50` stack: IsaacLab 2.2.0 / IsaacSim 5.0. RoboLab's `isaac50`/`isaac51` extras are not
# installed here: the base image already provides the matching IsaacLab/IsaacSim, so
# `pip install -e .` only pulls the non-isaac deps.
FROM nvcr.io/nvidia/isaac-lab:2.2.0

LABEL org.opencontainers.image.version="0.3.0"

# System packages
# Local addition: `ffmpeg`, which the upstream README requires for video recording but the upstream
# Dockerfile does not install.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential \
    ffmpeg \
    htop \
    iputils-ping \
    git-lfs \
    nvtop \
    tmux \
    vim \
    zip \
    && rm -rf /var/lib/apt/lists/*

# openpi-client (pinned to openpi server commit, no local deps)
ARG OPENPI_COMMIT=aa6420561529593114160d05e5ad155792b272f3
RUN /workspace/isaaclab/_isaac_sim/python.sh -m pip install --no-cache-dir --no-deps \
    "openpi-client @ git+https://github.com/xuningy/openpi@${OPENPI_COMMIT}#subdirectory=packages/openpi-client"

# Accept NVIDIA/Isaac Sim EULAs
ENV OMNI_KIT_ACCEPT_EULA=YES
ENV ACCEPT_EULA=Y

# Project code, cloned at the pinned commit instead of copied from the working tree.
# GIT_LFS_SKIP_SMUDGE=1 keeps the clone small; the assets are fetched in the next layer.
ARG ROBOLAB_REPO=https://github.com/NVlabs/RoboLab.git
ARG ROBOLAB_REF=f72d39445ab699c9cfd9bf551e8d21b6075293b9
RUN GIT_LFS_SKIP_SMUDGE=1 git clone ${ROBOLAB_REPO} /workspace/robolab && \
    cd /workspace/robolab && \
    git checkout ${ROBOLAB_REF}
WORKDIR /workspace/robolab

# Asset library (~7GB), which upstream bakes in through per-directory COPY layers. Kept in its own
# layer so code-only rebuilds reuse it. The local LFS object cache is dropped after checkout so the
# assets are not stored twice in the image.
RUN git lfs pull --include="assets/**" && \
    rm -rf .git/lfs

# Install Python dependencies
# GIT_LFS_SKIP_SMUDGE=1 avoids pulling large LFS objects during build
RUN GIT_LFS_SKIP_SMUDGE=1 /workspace/isaaclab/_isaac_sim/python.sh -m pip install --no-cache-dir -e .

ENV SHELL=/bin/bash

# Tools and scripts for Omniverse
COPY thirdparty/omnicli /omnicli
COPY scripts/docker/run.sh /run.sh

# Prevent users from accidentally removing the executable permission.
RUN chmod +x /omnicli/omnicli && chmod +x /run.sh
# Prevent users from accidentally saving script files with Windows line endings.
RUN sed -i 's/\r$//' /run.sh
