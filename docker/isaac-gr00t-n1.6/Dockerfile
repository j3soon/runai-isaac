# Ref: https://github.com/NVIDIA/Isaac-GR00T/blob/main/docker/Dockerfile
# Ref: https://github.com/NVIDIA/Isaac-GR00T/pull/563
FROM nvcr.io/nvidia/pytorch:25.04-py3

ENV NVIDIA_DRIVER_CAPABILITIES=graphics,utility,compute

RUN apt-get update && apt-get install -y \
    build-essential yasm cmake libtool git pkg-config \
    libass-dev libfreetype6-dev libvorbis-dev \
    autoconf automake texinfo tmux ffmpeg git-lfs

RUN pip install --upgrade pip setuptools
RUN pip install uv
RUN sed -i s/dill==0.3.9/dill==0.3.8/g /etc/pip/constraint.txt
RUN sed -i s/scipy==1.15.2/scipy==1.15.3/g /etc/pip/constraint.txt
RUN pip install imageio h5py boto3 transformers[torch] deepspeed timm peft diffusers wandb tianshou dm_tree openai albumentations==1.4.18 decord==0.6.0 torchcodec==0.4.0
RUN mkdir -p /opt
RUN cd /opt && git clone https://github.com/facebookresearch/pytorch3d.git
RUN cd /opt/pytorch3d && pip install .

# Adaptation for this repo: upstream Dockerfile expects `COPY src/gr00t/`.
# We clone and pin the GR00T source instead because this repo does not vendor it.
RUN git clone https://github.com/NVIDIA/Isaac-GR00T.git /workspace/gr00t
RUN cd /workspace/gr00t && git checkout e29d8fc50b0e4745120ae3fb72447986fe638aa6 && uv sync && uv pip install -e .

RUN apt-get update && apt-get install -y libegl1
RUN mkdir -p /usr/share/glvnd/egl_vendor.d && \
    cat >/usr/share/glvnd/egl_vendor.d/10_nvidia.json <<'EOF'
{
    "file_format_version" : "1.0.0",
    "ICD" : {
        "library_path" : "libEGL_nvidia.so.0"
    }
}
EOF

RUN mkdir -p /usr/share/vulkan/icd.d && \
    cat >/usr/share/vulkan/icd.d/nvidia_icd.json <<'EOF'
{
    "file_format_version": "1.0.0",
    "ICD": {
        "library_path": "libGLX_nvidia.so.0",
        "api_version": "1.2.140"
    }
}
EOF

# Tools and scripts for Omniverse
COPY thirdparty/omnicli /omnicli
COPY scripts/docker/run.sh /run.sh

# Prevent users from accidentally removing the executable permission.
RUN chmod +x /omnicli/omnicli && chmod +x /run.sh
# Prevent users from accidentally saving script files with Windows line endings.
RUN sed -i 's/\r$//' /run.sh
