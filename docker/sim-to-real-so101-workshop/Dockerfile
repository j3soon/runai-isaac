# Ref: https://github.com/isaac-sim/Sim-to-Real-SO-101-Workshop/blob/ce807d99724cb65671abec01f908a2fcb4a6eab7/docker/sim/Dockerfile
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# The upstream Dockerfile copies from its own working tree (`./docker/sim/entrypoint.sh`,
# `./docker/utils.sh`, and the `./source` tree mounted at run time), which is unavailable when
# building from this repository root. This is a self-contained variant that clones the upstream
# repo at a pinned commit instead, and bakes in the `source/` tree that upstream bind-mounts.
#
# Only upstream's sim/teleop container is covered here. Upstream's `docker/real/` images drive a
# physical SO-101 over `/dev/ttyACM*` with per-arm calibration and USB cameras, none of which
# exist on a Run:ai node.
FROM nvcr.io/nvidia/isaac-lab:2.3.2

LABEL org.opencontainers.image.version="1.0"

ENV PYTHON=/workspace/isaaclab/_isaac_sim/python.sh
ENV PATH="/workspace/isaaclab/_isaac_sim/kit/python/bin:$PATH"

# System packages
# Local addition: `git-lfs`, which the upstream Dockerfile does not need because it copies the
# already-smudged working tree, but which this clone-based variant requires for the USD/HDRI assets.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    git \
    git-lfs \
    libx11-6 libxcursor1 libxrandr2 libxi6 libxinerama1 \
    libxkbcommon0 libxkbcommon-x11-0 \
    && rm -rf /var/lib/apt/lists/*

# Accept NVIDIA/Isaac Sim EULAs
ENV OMNI_KIT_ACCEPT_EULA=YES
ENV ACCEPT_EULA=Y
ENV PRIVACY_CONSENT=Y

WORKDIR /workspace
RUN git clone https://github.com/huggingface/lerobot.git
WORKDIR /workspace/lerobot
RUN git checkout e670ac5daf9b76

# Install lerobot without deps to avoid upgrading packages that break
# Isaac Lab's symlinked vendored copies (packaging, numpy, torch, etc.)
RUN $PYTHON -m pip install --no-deps -e .

# Pin packages already in the base image to prevent upgrades that break
# Isaac Lab's internal symlinks (packaging, numpy, lxml, torch, etc.)
RUN printf '%s\n' \
    "packaging==23.0" \
    "numpy==1.26.0" \
    "lxml==4.9.4" \
    "torch==2.7.0" \
    "torchvision==0.22.0" \
    "imageio==2.37.0" \
    > /tmp/constraints.txt

# Install only the deps not already in the base image
RUN $PYTHON -m pip install -c /tmp/constraints.txt \
    "datasets>=4.0.0,<4.2.0" \
    "diffusers>=0.27.2,<0.36.0" \
    "huggingface-hub[hf-transfer,cli]>=0.34.2,<0.36.0" \
    "accelerate>=1.10.0,<2.0.0" \
    "cmake>=3.29.0.1,<4.2.0" \
    "av>=15.0.0,<16.0.0" \
    "jsonlines>=4.0.0,<5.0.0" \
    "pynput>=1.7.7,<1.9.0" \
    "pyserial>=3.5,<4.0" \
    "wandb>=0.20.0,<0.22.0" \
    "torchcodec>=0.2.1,<0.6.0" \
    "draccus==0.10.0" \
    "deepdiff>=7.0.1,<9.0.0" \
    "feetech-servo-sdk>=1.0.0,<2.0.0"

RUN curl --proto "=https" --tlsv1.2 -sSf -L -o /tmp/ffmpeg.tar.xz \
    https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-n7.1-latest-linux64-lgpl-shared-7.1.tar.xz && \
    tar -xf /tmp/ffmpeg.tar.xz -C /usr/local --strip-components=1 && \
    ldconfig && \
    rm /tmp/ffmpeg.tar.xz

# rerun-sdk requires numpy>=2 in its metadata but works fine with 1.26.0
RUN $PYTHON -m pip install --no-deps "rerun-sdk>=0.24.0,<0.27.0"
RUN $PYTHON -m pip install "pyzmq"

# Project code, cloned at the pinned commit instead of copied from the working tree.
# The commit is the latest on `main`; the four commits since the `v1.0` tag touch only the README
# and upstream's real-robot container, so this matches `v1.0` for the sim container covered here.
# GIT_LFS_SKIP_SMUDGE=1 keeps the clone small; the assets are fetched in the next layer.
ARG WORKSHOP_REPO=https://github.com/isaac-sim/Sim-to-Real-SO-101-Workshop.git
ARG WORKSHOP_REF=ce807d99724cb65671abec01f908a2fcb4a6eab7
RUN GIT_LFS_SKIP_SMUDGE=1 git clone ${WORKSHOP_REPO} /workspace/Sim-to-Real-SO-101-Workshop && \
    cd /workspace/Sim-to-Real-SO-101-Workshop && \
    git checkout ${WORKSHOP_REF}
WORKDIR /workspace/Sim-to-Real-SO-101-Workshop

# USD scenes, HDRI environment maps, and textures, tracked upstream through Git LFS. Without this
# the clone holds ~130-byte pointer files and the simulation fails at scene load rather than at
# build time. Kept in its own layer so code-only rebuilds reuse it; the local LFS object cache is
# dropped after checkout so the assets are not stored twice in the image.
RUN git lfs pull --include="source/sim_to_real_so101/assets/**" && \
    rm -rf .git/lfs
# Fail the build if any asset is still an LFS pointer rather than at scene load.
RUN test -z "$(find source/sim_to_real_so101/assets -name '*.usd*' -size -1k)" || \
    { echo "ERROR: Git LFS assets are still pointer files"; exit 1; }

# Local addition: upstream's entrypoint runs this install on every container start. Doing it at
# build time as well makes that a fast no-op and keeps pod startup from depending on the network.
RUN $PYTHON -m pip install -e /workspace/Sim-to-Real-SO-101-Workshop/source/sim_to_real_so101/

RUN $PYTHON -m pip install --upgrade pip

RUN mkdir -p /tmp/pycache && chmod 1777 /tmp/pycache
ENV PYTHONPYCACHEPREFIX=/tmp/pycache

# `docker/env` holds the physical robot's serial ports and camera indices. It is irrelevant to the
# sim container but `docker/utils.sh` and upstream's entrypoint both source it, so provide it.
RUN cp docker/env /root/env && \
    cat docker/utils.sh >> /root/.bashrc

ENV SHELL=/bin/bash

# Tools and scripts for Omniverse
COPY thirdparty/omnicli /omnicli
COPY scripts/docker/run.sh /run.sh

# Prevent users from accidentally removing the executable permission.
RUN chmod +x /omnicli/omnicli && chmod +x /run.sh && chmod +x docker/sim/entrypoint.sh
# Prevent users from accidentally saving script files with Windows line endings.
RUN sed -i 's/\r$//' /run.sh

ENTRYPOINT ["/workspace/Sim-to-Real-SO-101-Workshop/docker/sim/entrypoint.sh"]

CMD ["bash"]
