# Ref: https://github.com/yuantianyuan01/FastWAM/blob/7faa71108368fbb3b6885649f112af607427a2d4/README.md#environment-setup
# Copyright (c) 2026 The FastWAM Authors
# SPDX-License-Identifier: MIT

# Upstream ships no Dockerfile, so this is a self-contained image built from the README's
# `Environment Setup`, `Model Preparation`, and `Inference with Released Checkpoints` sections.
#
# Pinned at `7faa7110` (2026-08-20, `Optimize IDM action-only inference`), the HEAD of `main` at
# the time this image was added. FastWAM publishes no git tags and no releases, and its
# `pyproject.toml` version has stayed at `0.1.0` across the Optional IDM and 2x-inference updates,
# so a commit SHA is the only ref that identifies a build.

# Ubuntu 22.04 ships Python 3.10 in its default repositories, which is the version upstream's
# `conda create -n fastwam python=3.10` asks for, so no deadsnakes PPA is needed here.
# CUDA 12.8 matches the `+cu128` torch wheels upstream pins. `devel` rather than `runtime`, because
# DeepSpeed JIT-compiles its ZeRO ops against `nvcc` on first use by `scripts/train_zero1.sh`.
FROM nvidia/cuda:12.8.1-cudnn-devel-ubuntu22.04

LABEL org.opencontainers.image.source="https://github.com/yuantianyuan01/FastWAM"

SHELL ["/bin/bash", "-c"]

ENV DEBIAN_FRONTEND=noninteractive \
    NVIDIA_DRIVER_CAPABILITIES=graphics,utility,compute \
    CUDA_HOME=/usr/local/cuda \
    PATH=/usr/local/cuda/bin:${PATH} \
    LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH}

# System dependencies. `libegl1`/`libgl1-mesa-glx`/`libosmesa6-dev` and `patchelf` are MuJoCo's
# headless rendering requirements, pulled in for the LIBERO benchmark below; `ffmpeg` backs the
# `imageio-ffmpeg` and `torchcodec` video paths FastWAM uses for dataset loading and rollout videos.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        cmake \
        curl \
        ffmpeg \
        git \
        libegl1 \
        libgl1-mesa-glx \
        libglew-dev \
        libglfw3 \
        libglib2.0-0 \
        libosmesa6-dev \
        ninja-build \
        patchelf \
        pkg-config \
        python3.10 \
        python3.10-dev \
        python3.10-venv \
        python3-pip \
        wget \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# uv only builds and populates the virtual environment; the image itself runs out of it directly.
RUN curl --retry 5 --retry-delay 10 -LsSf https://astral.sh/uv/0.8.14/install.sh \
    | env UV_INSTALL_DIR=/usr/local/bin sh

ENV VIRTUAL_ENV=/opt/fastwam-venv
RUN uv venv --python python3.10 ${VIRTUAL_ENV}
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}"

# `pip install torch==2.7.1+cu128 torchvision==0.22.1+cu128` from upstream's `Environment Setup`.
# Installed before the project so the `+cu128` local-version wheels win over the PyPI defaults that
# `pyproject.toml`'s `torch==2.7.1+cu128` pin would otherwise have to resolve on its own.
# `--index-strategy unsafe-best-match` reproduces the behavior of the `pip` upstream uses. uv
# defaults to first-index-wins, which stops at the PyTorch index for every package it publishes a
# copy of, so the project install below fails on `packaging==25.0` (the PyTorch index carries
# `packaging`, but not that version). Both indexes here are the ones upstream already installs from.
ENV UV_INDEX_STRATEGY=unsafe-best-match
RUN uv pip install --no-cache \
        --extra-index-url https://download.pytorch.org/whl/cu128 \
        torch==2.7.1+cu128 torchvision==0.22.1+cu128

# Local pin for the upstream FastWAM source. Upstream never vendors a source tree into an image, so
# clone the pinned commit and install it editable, matching upstream's `pip install -e .`.
ARG FASTWAM_REPO=https://github.com/yuantianyuan01/FastWAM.git
ARG FASTWAM_REF=7faa71108368fbb3b6885649f112af607427a2d4
RUN git init /workspace/fastwam && \
    cd /workspace/fastwam && \
    git remote add origin ${FASTWAM_REPO} && \
    git fetch --depth 1 origin ${FASTWAM_REF} && \
    git checkout FETCH_HEAD

WORKDIR /workspace/fastwam
RUN uv pip install --no-cache \
        --extra-index-url https://download.pytorch.org/whl/cu128 \
        -e .

# LIBERO benchmark environment. Upstream's `Inference with Released Checkpoints` section tells the
# user to install this separately from the LIBERO repository, then `pip install mujoco==3.3.2`.
#
# LIBERO's own `requirements.txt` pins `numpy==1.22.4` and `transformers==4.21.1`, which contradict
# FastWAM's `numpy==2.2.6` and `transformers==4.49.0`, and FastWAM's evaluation imports both
# packages into one process. Its `setup.py` declares `install_requires=[]`, so installing the
# package itself pulls nothing; the runtime dependencies that `libero.libero.envs` and
# `libero.libero.benchmark` actually import are listed explicitly here instead, unpinned except
# where upstream pins them. The dropped pins belong to the `libero.lifelong` training stack, which
# FastWAM does not use.
#
# `future` is listed because `bddl==1.0.1` imports `future.utils.with_metaclass` at module scope
# without declaring the dependency, so `from libero.libero.envs import OffScreenRenderEnv` fails
# with `ModuleNotFoundError: No module named 'future'` if only `bddl`'s own metadata is trusted.
ARG LIBERO_REPO=https://github.com/Lifelong-Robot-Learning/LIBERO.git
ARG LIBERO_REF=8f1084e3132a39270c3a13ebe37270a43ece2a01
RUN git init /workspace/LIBERO && \
    cd /workspace/LIBERO && \
    git remote add origin ${LIBERO_REPO} && \
    git fetch --depth 1 origin ${LIBERO_REF} && \
    git checkout FETCH_HEAD

# `editable_mode=compat` is required, not a preference. LIBERO has no `libero/__init__.py`, so it
# is an implicit namespace package, and `setup.py`'s `find_packages()` cannot discover one: a
# default editable install under modern setuptools writes a finder with an empty `MAPPING` and
# `import libero` fails with `ModuleNotFoundError` even though `pip list` shows `libero 0.1.0`.
# Compat mode writes a plain `.pth` holding the project root instead, which resolves the namespace.
RUN uv pip install --no-cache \
        robosuite==1.4.0 \
        bddl==1.0.1 \
        gym==0.25.2 \
        cloudpickle \
        easydict \
        future \
        matplotlib \
        mujoco==3.3.2 && \
    uv pip install --no-cache --no-deps -e /workspace/LIBERO \
        --config-settings editable_mode=compat

# `import libero.libero` prompts on stdin with `input("Do you want to specify a custom path for the
# dataset folder? (Y/N): ")` whenever `~/.libero/config.yaml` is absent, and a non-interactive
# Run:ai workload answers that with EOF: the import dies with `EOFError: EOF when reading a line`
# before any FastWAM code runs. Answer `N` once at build time so the module writes its own default
# config and every later import is silent.
RUN echo "N" | python -c "import libero.libero" && \
    cat /root/.libero/config.yaml

# EGL setup for headless MuJoCo rendering, so LIBERO's `OffScreenRenderEnv` works without an X
# server.
RUN mkdir -p /usr/share/glvnd/egl_vendor.d && \
    cat >/usr/share/glvnd/egl_vendor.d/10_nvidia.json <<'JSONEOF'
{
    "file_format_version" : "1.0.0",
    "ICD" : {
        "library_path" : "libEGL_nvidia.so.0"
    }
}
JSONEOF

ENV MUJOCO_GL=egl \
    PYOPENGL_PLATFORM=egl \
    __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/10_nvidia.json

# Default for upstream's `export DIFFSYNTH_MODEL_BASE_PATH="$(pwd)/checkpoints"`. Point it at a
# persistent mount to keep the Wan2.2-TI2V-5B download across workloads; see the application guide.
ENV DIFFSYNTH_MODEL_BASE_PATH=/workspace/fastwam/checkpoints

# The LIBERO evaluation manager supervises per-GPU worker subprocesses and reports progress as it
# goes; without this its status lines stay buffered and a healthy run looks hung.
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
