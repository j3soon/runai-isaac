# Ref: https://github.com/nvidia-cosmos/cosmos-predict2.5/blob/main/Dockerfile
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Dockerfile using uv environment.

ARG TARGETPLATFORM
ARG BASE_IMAGE=nvidia/cuda:12.8.1-cudnn-devel-ubuntu24.04

FROM ${BASE_IMAGE}

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
COPY --from=ghcr.io/astral-sh/uv:0.8.12 /uv /uvx /usr/local/bin/
# Copy from the cache instead of linking since it's a mounted volume
ENV UV_LINK_MODE=copy
# Ensure installed tools can be executed out of the box
ENV UV_TOOL_BIN_DIR=/usr/local/bin

# Install just: https://just.systems/man/en/pre-built-binaries.html
RUN curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --to /usr/local/bin --tag 1.42.4

WORKDIR /workspace

ARG COSMOS_PREDICT25_REPO=https://github.com/nvidia-cosmos/cosmos-predict2.5.git
ARG COSMOS_PREDICT25_REF=fe9585e79280ed90d58074ebf09698bfda249f93
RUN git clone ${COSMOS_PREDICT25_REPO} /workspace && \
    cd /workspace && \
    git checkout ${COSMOS_PREDICT25_REF}

# Install the project's dependencies using the lockfile and settings.
ARG CUDA_NAME=cu128
ENV CUDA_NAME=${CUDA_NAME}
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked --no-install-project --extra=${CUDA_NAME}

RUN just install && rm -rf /workspace/.git

# Place executables in the environment at the front of the path
ENV PATH="/workspace/.venv/bin:$PATH"
ENV SHELL=/bin/bash

# Tools and scripts for Omniverse
COPY thirdparty/omnicli /omnicli
COPY scripts/docker/run.sh /run.sh

# Prevent users from accidentally removing the executable permission.
RUN chmod +x /omnicli/omnicli && chmod +x /run.sh
# Prevent users from accidentally saving script files with Windows line endings.
RUN sed -i 's/\r$//' /run.sh

ENTRYPOINT ["/workspace/bin/entrypoint.sh"]

CMD ["/bin/bash"]
