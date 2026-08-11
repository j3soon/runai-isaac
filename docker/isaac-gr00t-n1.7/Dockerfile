# syntax=docker/dockerfile:1
# Ref: https://github.com/NVIDIA/Isaac-GR00T/blob/1a1837f20538b7d7e21f977a11a5aee14f99803c/docker/Dockerfile
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Pinned at the upstream commit whose subject is `GR00T N1.7 General Release` (2026-07-07).
# This is deliberately NOT the `n1.7-release` tag (`23ace64f`, 2026-04-18, subject
# `GR00T N1.7 Release`), which is an earlier N1.7 build that upstream superseded without moving
# or adding a tag. The General Release serializes with `msgpack_numpy`; the tagged build uses
# plain `msgpack` and rejects a RoboLab client's arrays as `<class 'dict'>`. See
# `docker/isaac-gr00t-n1.7/README.md`.
#
# N1.7 uses CUDA 12.8 / Python 3.12 / torch 2.9, a different stack from the N1.6 image in this
# repository, so it gets its own folder.

FROM nvidia/cuda:12.8.0-devel-ubuntu24.04

LABEL org.opencontainers.image.version="n1.7"

SHELL ["/bin/bash", "-c"]

ENV DEBIAN_FRONTEND=noninteractive \
    NVIDIA_DRIVER_CAPABILITIES=graphics,utility,compute \
    GR00T_GLOBAL_VENV=/opt/gr00t-venv \
    UV_PROJECT_ENVIRONMENT=/opt/gr00t-venv \
    PYTHON=/usr/bin/python \
    CUDA_HOME=/usr/local/cuda \
    PATH=/usr/local/cuda/bin:${PATH} \
    LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH}

# System dependencies
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked <<INNEREOF
set -euo pipefail
APT_RETRY_OPTS=(
    -o Acquire::Retries=5
    -o Acquire::http::Timeout=30
    -o Acquire::https::Timeout=30
)
find /etc/apt -type f \( -name '*.list' -o -name '*.sources' \) -exec sed -i \
    -e 's|http://archive.ubuntu.com/ubuntu|https://archive.ubuntu.com/ubuntu|g' \
    -e 's|http://security.ubuntu.com/ubuntu|https://security.ubuntu.com/ubuntu|g' \
    {} +

apt_update() {
    for attempt in 1 2 3 4 5; do
        if apt-get "${APT_RETRY_OPTS[@]}" update -o APT::Update::Error-Mode=any; then
            return 0
        fi
        rm -rf /var/lib/apt/lists/*
        sleep $((attempt * 10))
    done
    return 1
}

apt_update

apt-get "${APT_RETRY_OPTS[@]}" install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    git \
    git-lfs \
    curl \
    wget \
    python3.12 \
    python3.12-venv \
    python3.12-dev \
    python3-pip \
    python-is-python3 \
    software-properties-common \
    cmake \
    ninja-build \
    pkg-config \
    pybind11-dev \
    ffmpeg \
    libavdevice-dev \
    libavfilter-dev \
    libavformat-dev \
    libavcodec-dev \
    libavutil-dev \
    libswresample-dev \
    libswscale-dev \
    libegl1

# The sim-eval setup scripts (LIBERO, SimplerEnv, RoboCasa*) build isolated
# `uv venv --python 3.10` islands whose deps pin an older torch, so the image must still ship a
# 3.10 interpreter even though the GR00T root env is 3.12. ubuntu24.04 has no python3.10 in its
# default repos -> deadsnakes.
add-apt-repository -y ppa:deadsnakes/ppa
apt_update
apt-get "${APT_RETRY_OPTS[@]}" install -y --no-install-recommends \
    python3.10 \
    python3.10-venv \
    python3.10-dev

# Ubuntu 24.04's system Python is PEP 668 "externally managed"; this only bootstraps
# pip/setuptools/wheel before uv builds its own venv, so opting out is safe inside the image.
python -m pip install --upgrade --retries 5 --break-system-packages --ignore-installed pip setuptools wheel

curl --retry 5 --retry-delay 10 --retry-max-time 300 -LsSf https://astral.sh/uv/0.8.14/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh
INNEREOF

# Adaptation for this repo: upstream copies its own working tree (`COPY pyproject.toml uv.lock`
# into a temporary build dir) and never ships the source, so `gr00t` is not importable in the
# upstream image and callers must bind-mount the tree and set `PYTHONPATH`. Clone the pinned
# commit into `/workspace` instead and install the project, matching the N1.6 image in this
# repository. GIT_LFS_SKIP_SMUDGE=1 leaves the LFS-tracked demo media and the aarch64-only
# `scripts/deployment/*/wheels/*.whl` as pointer files: the wheel paths still exist, which is all
# `pyproject.toml` needs on x86_64, where those path sources are not selected.
ARG ISAAC_GR00T_REPO=https://github.com/NVIDIA/Isaac-GR00T.git
ARG ISAAC_GR00T_REF=1a1837f20538b7d7e21f977a11a5aee14f99803c
RUN GIT_LFS_SKIP_SMUDGE=1 git clone ${ISAAC_GR00T_REPO} /workspace && \
    cd /workspace && \
    git checkout ${ISAAC_GR00T_REF}
WORKDIR /workspace

# Install Python dependencies from lockfile into the shared venv, then the project itself.
RUN <<INNEREOF
set -euo pipefail
UV_PREVIEW=1 UV_HTTP_TIMEOUT=300 UV_CONCURRENT_DOWNLOADS=4 uv sync --frozen --no-install-project --extra dev --no-cache
uv pip install --python "${GR00T_GLOBAL_VENV}/bin/python" -e . --no-deps
sha256sum uv.lock | awk '{print $1}' > "${GR00T_GLOBAL_VENV}/.gr00t-uv-lock.sha256"
mkdir -p /opt/gr00t-image-metadata
cp pyproject.toml uv.lock /opt/gr00t-image-metadata/
INNEREOF

ENV PATH="${GR00T_GLOBAL_VENV}/bin:${PATH}" \
    VIRTUAL_ENV="${GR00T_GLOBAL_VENV}"

# EGL/Vulkan setup for headless rendering (MuJoCo, PyOpenGL)
RUN mkdir -p /usr/share/glvnd/egl_vendor.d && \
    cat >/usr/share/glvnd/egl_vendor.d/10_nvidia.json <<'JSONEOF'
{
    "file_format_version" : "1.0.0",
    "ICD" : {
        "library_path" : "libEGL_nvidia.so.0"
    }
}
JSONEOF

RUN mkdir -p /usr/share/vulkan/icd.d && \
    cat >/usr/share/vulkan/icd.d/nvidia_icd.json <<'JSONEOF'
{
    "file_format_version": "1.0.0",
    "ICD": {
        "library_path": "libGLX_nvidia.so.0",
        "api_version": "1.2.140"
    }
}
JSONEOF

ENV MUJOCO_GL="egl" \
    PYOPENGL_PLATFORM="egl" \
    __EGL_VENDOR_LIBRARY_FILENAMES="/usr/share/glvnd/egl_vendor.d/10_nvidia.json"

# The policy server's readiness banner is buffered otherwise, so a healthy server looks hung.
ENV PYTHONUNBUFFERED=1
ENV SHELL=/bin/bash

# Tools and scripts for Omniverse
COPY thirdparty/omnicli /omnicli
COPY scripts/docker/run.sh /run.sh

# Prevent users from accidentally removing the executable permission.
RUN chmod +x /omnicli/omnicli && chmod +x /run.sh
# Prevent users from accidentally saving script files with Windows line endings.
RUN sed -i 's/\r$//' /run.sh

CMD ["/bin/bash"]
