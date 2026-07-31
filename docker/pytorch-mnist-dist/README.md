# PyTorch Distributed MNIST

This image follows the Kubeflow Trainer distributed MNIST example and is intended for PyTorch distributed training on NVIDIA Run:ai.

The Dockerfile and `mnist.py` are pinned to Kubeflow Trainer commit [`8e41c03c1cabf2f0800efa6abb06084d094fd94f`](https://github.com/kubeflow/trainer/tree/8e41c03c1cabf2f0800efa6abb06084d094fd94f/examples/pytorch/mnist). This is the source revision used by both the `kubeflow/pytorch-dist-mnist:latest` and `kubeflow/pytorch-dist-mnist:v1-8e41c03` images at the time of writing. Pinning the full commit keeps the Dockerfile and training script together when upstream tags move.

## Build

Use the pre-built `j3soon/runai-pytorch-dist-mnist` image, or build it from the repository root:

```sh
docker build -t j3soon/runai-pytorch-dist-mnist -f docker/pytorch-mnist-dist/Dockerfile .
```

## Run on NVIDIA Run:ai

Follow the NVIDIA Run:ai [distributed training quick start](https://run-ai-docs.nvidia.com/self-hosted/workloads-in-nvidia-run-ai/using-training/quick-starts/distributed-training-quickstart#ui-flexible), with these values:

1. Go to **Workload manager** → **Workloads**, select **+NEW WORKLOAD** → **Training**, then choose the cluster and project.
2. Select **Distributed** as the Workload architecture.
3. Select **PyTorch**, **Worker & master**, and **Start from scratch**.
4. Enter a workload name and continue.
5. Use `j3soon/runai-pytorch-dist-mnist` as the image URL and set `Image pull` to `Always pull the image from the registry`.
6. Select a compute resource with `gpu-x1` (1 GPU per pod), and keep `Set the number of workers for your workload` as `1` (total 2 GPUs, for worker and master), for simple testing. Usually you should select `gpu-x8` for a total of 16 GPUs.
7. Enter the following in `Runtime settings > Command`:
   ```sh
   /run.sh "torchrun --nproc_per_node=8 /opt/mnist/src/mnist.py"
   ```
8. Click `CONTINUE` and `CREATE TRAINING` to create the training workload.

The example uses the Gloo distributed backend by default. The logs should show the world size and rank assigned to each pod. Select the workload, click `LOGS`, select the corresponding `Pods`, and check its logs.

## Local testing

The following CPU-only test approximates the container-level environment created by Kubeflow. It launches two containers on the same Docker network, with one rank acting as the rendezvous endpoint:

```sh
MNIST_IMAGE=j3soon/runai-pytorch-dist-mnist

docker network create pytorch-dist-mnist-test
docker volume create pytorch-dist-mnist-test-data

# Download FashionMNIST once without running a training epoch.
docker run --rm \
  --mount type=volume,src=pytorch-dist-mnist-test-data,dst=/opt/mnist/data \
  "$MNIST_IMAGE" \
  --no-cuda --epochs 0

docker run -d \
  --name pytorch-dist-mnist-rank0 \
  --network pytorch-dist-mnist-test \
  --mount type=volume,src=pytorch-dist-mnist-test-data,dst=/opt/mnist/data,readonly \
  -e RANK=0 -e WORLD_SIZE=2 \
  -e MASTER_ADDR=pytorch-dist-mnist-rank0 -e MASTER_PORT=29500 \
  -e OMP_NUM_THREADS=1 \
  "$MNIST_IMAGE" \
  --no-cuda --backend gloo --epochs 1 \
  --batch-size 1024 --test-batch-size 5000

docker run -d \
  --name pytorch-dist-mnist-rank1 \
  --network pytorch-dist-mnist-test \
  --mount type=volume,src=pytorch-dist-mnist-test-data,dst=/opt/mnist/data,readonly \
  -e RANK=1 -e WORLD_SIZE=2 \
  -e MASTER_ADDR=pytorch-dist-mnist-rank0 -e MASTER_PORT=29500 \
  -e OMP_NUM_THREADS=1 \
  "$MNIST_IMAGE" \
  --no-cuda --backend gloo --epochs 1 \
  --batch-size 1024 --test-batch-size 5000

# Both exit codes should be 0.
docker wait pytorch-dist-mnist-rank0 pytorch-dist-mnist-rank1
docker logs pytorch-dist-mnist-rank0
docker logs pytorch-dist-mnist-rank1
```

The logs should contain `World Size: 2. Rank: 0`, `World Size: 2. Rank: 1`, and an `accuracy=` result from each container. This validates the image entrypoint, rendezvous, rank configuration, and distributed training across separate containers. It does not test Kubeflow controller behavior such as `PyTorchJob` creation, services, retries, or pod lifecycle management.

Clean up the stopped containers, network, and dataset volume after testing. The same commands can clean up an interrupted test:

```sh
docker rm -f pytorch-dist-mnist-rank0 pytorch-dist-mnist-rank1 2>/dev/null || true
docker network rm pytorch-dist-mnist-test 2>/dev/null || true
docker volume rm pytorch-dist-mnist-test-data 2>/dev/null || true
```
