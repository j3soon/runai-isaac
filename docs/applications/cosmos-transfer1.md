# Cosmos-Transfer1

This page is part of the sample applications guide. Follow [README](../../README.md) first and stop interactive workloads when finished.

Create a docker image for [cosmos-transfer1](https://github.com/nvidia-cosmos/cosmos-transfer1) following the [installation guide](https://github.com/nvidia-cosmos/cosmos-transfer1/blob/main/INSTALL.md):

```sh
docker build -f docker/cosmos-transfer1/Dockerfile . -t j3soon/runai-cosmos-transfer1:latest
docker push j3soon/runai-cosmos-transfer1:latest
```

```sh
CUDA_HOME=$CONDA_PREFIX PYTHONPATH=$(pwd) python scripts/test_environment.py
```

> TODO
