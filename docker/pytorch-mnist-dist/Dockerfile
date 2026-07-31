# Ref: https://github.com/kubeflow/trainer/blob/8e41c03c1cabf2f0800efa6abb06084d094fd94f/examples/pytorch/mnist/Dockerfile
# Commit 8e41c03 is pinned because kubeflow/pytorch-dist-mnist:latest currently
# matches v1-8e41c03 on Docker Hub. This keeps the Dockerfile and training script
# aligned with that published reference image if the upstream latest tag changes.

# We need to use the nvcr.io/nvidia/pytorch image as a base image to support both linux/amd64 and linux_arm64 platforms.
# PyTorch=2.2.0, cuda=12.3.2
# Ref: https://docs.nvidia.com/deeplearning/frameworks/pytorch-release-notes/rel-24-01.html#rel-24-01
FROM nvcr.io/nvidia/pytorch:24.01-py3

RUN pip install tensorboardX==2.6.2

RUN mkdir -p /opt/mnist
WORKDIR /opt/mnist/src

# Ref: https://github.com/kubeflow/trainer/blob/8e41c03c1cabf2f0800efa6abb06084d094fd94f/examples/pytorch/mnist/mnist.py
ADD https://raw.githubusercontent.com/kubeflow/trainer/8e41c03c1cabf2f0800efa6abb06084d094fd94f/examples/pytorch/mnist/mnist.py /opt/mnist/src/mnist.py

RUN chgrp -R 0 /opt/mnist \
    && chmod -R g+rwX /opt/mnist

ENTRYPOINT ["python", "/opt/mnist/src/mnist.py"]

ENV SHELL=/bin/bash

# Tools and scripts for Omniverse
COPY thirdparty/omnicli /omnicli
COPY scripts/docker/run.sh /run.sh

# Prevent users from accidentally removing the executable permission.
RUN chmod +x /omnicli/omnicli && chmod +x /run.sh
# Prevent users from accidentally saving script files with Windows line endings.
RUN sed -i 's/\r$//' /run.sh
