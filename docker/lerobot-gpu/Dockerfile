# Ref: https://github.com/huggingface/lerobot/blob/8fff0fde7c79f23a93d845d1a50e985de01f8b8a/docker/Dockerfile.internal
# Copyright 2025 The HuggingFace Inc. team. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# This Dockerfile is designed for HuggingFace internal CI environments
# that require GPU access. It starts from an NVIDIA CUDA base image.

# docker build -f docker/Dockerfile.internal -t lerobot-internal .

# Configure the base image for CI with GPU access
# TODO(Steven): Bump these versions
ARG CUDA_VERSION=12.4.1
ARG OS_VERSION=22.04
FROM nvidia/cuda:${CUDA_VERSION}-base-ubuntu${OS_VERSION}

# Define Python version argument
ARG PYTHON_VERSION=3.10

# Local pin for the upstream LeRobot source.
ARG LEROBOT_REPO=https://github.com/huggingface/lerobot.git
ARG LEROBOT_REF=8fff0fde7c79f23a93d845d1a50e985de01f8b8a

# Configure environment variables
ENV DEBIAN_FRONTEND=noninteractive \
    MUJOCO_GL=egl \
    PATH=/lerobot/.venv/bin:$PATH \
    CUDA_VISIBLE_DEVICES=0 \
    TEST_TYPE=single_gpu \
    DEVICE=cuda \
    SHELL=/bin/bash

# Install Python, system dependencies, and uv (as root)
RUN apt-get update && apt-get install -y --no-install-recommends \
    software-properties-common build-essential git curl \
    libglib2.0-0 libgl1-mesa-glx libegl1-mesa ffmpeg \
    libusb-1.0-0-dev speech-dispatcher libgeos-dev portaudio19-dev \
    cmake pkg-config ninja-build \
    && add-apt-repository -y ppa:deadsnakes/ppa \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
       python${PYTHON_VERSION} \
       python${PYTHON_VERSION}-venv \
       python${PYTHON_VERSION}-dev \
    && curl -LsSf https://astral.sh/uv/install.sh | sh \
    && mv /root/.local/bin/uv /usr/local/bin/uv \
    && useradd --create-home --shell /bin/bash user_lerobot \
    && usermod -aG sudo user_lerobot \
    && git init /lerobot \
    && cd /lerobot \
    && git remote add origin ${LEROBOT_REPO} \
    && git fetch --depth 1 origin ${LEROBOT_REF} \
    && git checkout FETCH_HEAD \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Create application directory and set permissions
WORKDIR /lerobot
RUN chown -R user_lerobot:user_lerobot /lerobot

# Switch to the non-root user
USER user_lerobot

# Environment variables for the testing
ENV HOME=/home/user_lerobot \
    HF_HOME=/home/user_lerobot/.cache/huggingface \
    HF_LEROBOT_HOME=/home/user_lerobot/.cache/huggingface/lerobot \
    TORCH_HOME=/home/user_lerobot/.cache/torch \
    TRITON_CACHE_DIR=/home/user_lerobot/.cache/triton

# Create the virtual environment
# We use a virtual environment inside the container—even though the container itself \
# provides isolation—to ensure compatibility with the cluster and to prevent \
# issues with MuJoCo and OpenGL drivers.
RUN uv venv --python python${PYTHON_VERSION}

ARG UNBOUND_DEPS=false

RUN if [ "$UNBOUND_DEPS" = "true" ]; then \
    sed -i 's/,[[:space:]]*<[0-9\.]*//g' pyproject.toml; \
    echo "Dependencies unbound:" && cat pyproject.toml; \
    fi

RUN uv pip install --no-cache ".[all]"

RUN chmod +x /lerobot/.venv/lib/python${PYTHON_VERSION}/site-packages/triton/backends/nvidia/bin/ptxas

USER root

COPY thirdparty/omnicli /omnicli
COPY scripts/docker/run.sh /run.sh

# Repo-standard helper files for Run:ai workflows.
RUN chmod +x /omnicli/omnicli && chmod +x /run.sh

RUN sed -i 's/\r$//' /run.sh

# Set the default command
CMD ["/bin/bash"]
