# syntax = docker/dockerfile:1.7
# Ref: https://github.com/HCIS-Lab/aicapstone/blob/9dd61f693f2db770338ce84fdd232dd7040c9555/Dockerfile
# SPDX-FileCopyrightText: Copyright (c) 2026 HCIS-Lab
# SPDX-License-Identifier: MIT

# The upstream Dockerfile builds from its own working tree: it `COPY`s `dependencies/IsaacLab`
# (a git submodule) and `packages/simulator`, neither of which exists when building from this
# repository root. This is a self-contained variant that clones the upstream repo at a pinned
# commit and initializes the submodule during the build instead.
#
# It also bakes in the whole project tree. Upstream's `make launch-isaaclab-*` targets bind-mount
# the host clone over `/workspace/aicapstone` at run time, so upstream's image only needs the two
# directories above; without that mount the image additionally needs `scripts/` and the USD/texture
# assets under `packages/simulator/assets/`, which are committed as plain git blobs (no Git LFS).
#
# Upstream publishes no tags or releases, so `main` is pinned at the commit below (2026-08-04).
# That commit records the `dependencies/IsaacLab` submodule at
# 4df6560e187f2cc66685b41b21b259f4485d0c22, which `git submodule update` restores exactly.
#
# The base matches upstream. A 24.04 base was trialled while chasing a Vulkan failure on Brev/AWS
# and did NOT fix it: the cause is the host's 595-to-580 driver downgrade on Brev's AWS base, which
# leaves the driver's graphics userspace broken, not anything in this image. Deploy on a provider
# whose base already ships a 580-branch driver (see this image's README) and it renders unmodified.
#
# Only the data-generation surface is covered. Upstream's rollout step needs a trained checkpoint,
# and upstream directs training to the host rather than into this container.
FROM nvidia/cuda:12.8.1-devel-ubuntu22.04

ARG DEBIAN_FRONTEND=noninteractive
ARG PYTHON_VERSION=3.11

ENV NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=all \
    PIP_NO_CACHE_DIR=1 \
    PIP_DEFAULT_TIMEOUT=300 \
    PIP_RETRIES=5 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    ACCEPT_EULA=Y \
    OMNI_KIT_ACCEPT_EULA=YES \
    PRIVACY_CONSENT=Y \
    TERM=xterm-256color

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN echo 'Acquire::Retries "5";' > /etc/apt/apt.conf.d/80-retries \
    && echo 'Acquire::https::Timeout "120";' >> /etc/apt/apt.conf.d/80-retries \
    && echo 'Acquire::http::Timeout "120";' >> /etc/apt/apt.conf.d/80-retries

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gpg \
    && curl --retry 5 --retry-delay 10 --retry-all-errors -fsSL \
        "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0xF23C5A6CF475977595C89F51BA6932366A755776" \
        | gpg --dearmor -o /usr/share/keyrings/deadsnakes.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/deadsnakes.gpg] https://ppa.launchpadcontent.net/deadsnakes/ppa/ubuntu jammy main" \
        > /etc/apt/sources.list.d/deadsnakes.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        cmake \
        curl \
        git \
        libasound2 \
        libdbus-1-3 \
        libegl1 \
        libfontconfig1 \
        libgl1 \
        libglu1-mesa \
        libglib2.0-0 \
        libgtk-3-0 \
        libice6 \
        libnss3 \
        libsm6 \
        libvulkan1 \
        libx11-6 \
        libx11-xcb1 \
        libxcb-cursor0 \
        libxcb-icccm4 \
        libxcb-image0 \
        libxcb-keysyms1 \
        libxcb-render-util0 \
        libxcb-xinerama0 \
        libxcb-xkb1 \
        libxcursor1 \
        libxext6 \
        libxi6 \
        libxinerama1 \
        libxkbcommon-x11-0 \
        libxrandr2 \
        libxrender1 \
        libxt6 \
        libxtst6 \
        libxxf86vm1 \
        python${PYTHON_VERSION} \
        python${PYTHON_VERSION}-dev \
        python${PYTHON_VERSION}-distutils \
        python${PYTHON_VERSION}-venv \
        unzip \
        vulkan-tools \
        wget \
    && ln -sf /usr/bin/python${PYTHON_VERSION} /usr/local/bin/python \
    && ln -sf /usr/bin/python${PYTHON_VERSION} /usr/local/bin/python3 \
    && curl --retry 5 --retry-delay 10 --retry-all-errors -fsSL https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py \
    && python /tmp/get-pip.py \
    && rm -f /tmp/get-pip.py \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/aicapstone

RUN python -m pip install --upgrade pip \
    && python -m pip install -U \
        torch==2.7.0 \
        torchvision==0.22.0 \
        --index-url https://download.pytorch.org/whl/cu128 \
    && python -m pip install --upgrade \
        "isaacsim[all,extscache]==5.1.0" \
        --extra-index-url https://pypi.nvidia.com \
    && python -m pip install \
        pip==23 \
        setuptools==65 \
        flatdict==4.0.0 \
        huggingface-hub==0.35.3 \
        transformers==4.57.6

# Local addition: replaces upstream's two `COPY` instructions. Kept after the heavy pip layer, in
# the same position the `COPY`s occupied, so a change to the pinned commit does not invalidate the
# Isaac Sim install above.
ARG AICAPSTONE_REPO=https://github.com/HCIS-Lab/aicapstone.git
ARG AICAPSTONE_REF=9dd61f693f2db770338ce84fdd232dd7040c9555
RUN git clone ${AICAPSTONE_REPO} /workspace/aicapstone \
    && git -C /workspace/aicapstone checkout ${AICAPSTONE_REF} \
    && git -C /workspace/aicapstone submodule update --init --recursive

# Upstream guard, kept verbatim: it catches an uninitialized submodule at build time rather than
# part-way through the Isaac Lab install.
RUN test -x dependencies/IsaacLab/isaaclab.sh || \
    (echo "dependencies/IsaacLab is not initialized. Run 'git submodule update --init --recursive' before 'docker build'." >&2; exit 1)

RUN python -m pip install --no-deps \
        setuptools==65 \
        wheel==0.45.1 \
        toml==0.10.2 \
        packaging==23.0 \
        poetry-core==2.2.1 \
    && sed -i 's|-m pip install"|-m pip install --no-build-isolation"|' \
        dependencies/IsaacLab/isaaclab.sh \
    && cd dependencies/IsaacLab \
    && ./isaaclab.sh --install

RUN python -m pip install --no-deps numpy==1.26.0

RUN python -m pip install --upgrade \
        setuptools==80.10.2 \
        wheel==0.45.1 \
        cython==3.0.11 \
        toml==0.10.2 \
        packaging==24.2

# Local addition: `packages/simulator` declares
# `leisaac @ git+https://github.com/LightwheelAI/leisaac.git#subdirectory=source/leisaac` with no
# ref, so it resolves to whatever LightwheelAI's default branch points at and the same build
# produces a different image over time. Pin it to the commit that branch currently resolves to
# (2026-04-15), which is what an unpinned upstream build gets today.
#
# Do not "fix" this to the latest tag: v0.4.0 is 1651c321e9b0c1bb54233211fc7b3cd70d8373d5, which is
# *older* than the branch head below, so pinning the tag would silently change behavior rather than
# freeze it. The `grep` asserts the substitution matched, so an upstream edit to that dependency
# line fails the build here instead of quietly restoring the moving ref.
ARG LEISAAC_REF=24d3bcd3f1e4585740fc79921782c41617237812
RUN sed -i "s|leisaac @ git+https://github.com/LightwheelAI/leisaac.git#subdirectory=source/leisaac|leisaac @ git+https://github.com/LightwheelAI/leisaac.git@${LEISAAC_REF}#subdirectory=source/leisaac|" \
        packages/simulator/pyproject.toml \
    && grep -q "leisaac.git@${LEISAAC_REF}#subdirectory=source/leisaac" packages/simulator/pyproject.toml

RUN printf "numpy==1.26.0\n" > /tmp/sim-constraints.txt \
    && python -m pip install --use-deprecated=legacy-resolver \
        --no-build-isolation \
        -c /tmp/sim-constraints.txt \
        -e packages/simulator \
    && python -m pip install --no-deps numpy==1.26.0 \
    && rm -f /tmp/sim-constraints.txt

RUN python -m pip install --upgrade pip==26.0.1 \
    && python -m pip install --no-deps numpy==1.26.0

# Local addition: register NVIDIA as a GLVND EGL vendor. Upstream omits this because its target
# has a desktop driver install that provides the file; a container gets only what the NVIDIA
# container toolkit injects, and the toolkit injects the Vulkan ICD but not this.
#
# Without it, `vkCreateInstance` fails with ERROR_INCOMPATIBLE_DRIVER on a host whose driver was
# installed by downgrading (Brev's AWS base ships 595 and Isaac Sim 5.1.0 needs 580), and Isaac Sim
# aborts with `Failed to create any GPU devices`, so `--enable_cameras` cannot run. The NVIDIA
# Vulkan ICD reaches the GPU through EGL/GBM when there is no display, and that path needs a
# registered EGL vendor. Hosts whose driver was installed normally are unaffected, which is why
# this only shows up on some providers.
#
# Verified on a Brev g6e.xlarge (driver 580.178.04, downgraded from 595): without this file
# `vulkaninfo` reports ERROR_INCOMPATIBLE_DRIVER, with it `deviceName = NVIDIA L40S` and datagen
# runs. Matches what this repository's isaac-lab-ex-ros2 image writes, which is why that image
# renders on hosts where this one previously could not.
RUN mkdir -p /usr/share/glvnd/egl_vendor.d && \
    printf '%s\n' \
      '{' \
      '    "file_format_version" : "1.0.0",' \
      '    "ICD" : {' \
      '        "library_path" : "libEGL_nvidia.so.0"' \
      '    }' \
      '}' \
      > /usr/share/glvnd/egl_vendor.d/10_nvidia.json

ENV SHELL=/bin/bash

# Tools and scripts for Omniverse
COPY thirdparty/omnicli /omnicli
COPY scripts/docker/run.sh /run.sh

# Prevent users from accidentally removing the executable permission.
RUN chmod +x /omnicli/omnicli && chmod +x /run.sh
# Prevent users from accidentally saving script files with Windows line endings.
RUN sed -i 's/\r$//' /run.sh

CMD ["/bin/bash"]
