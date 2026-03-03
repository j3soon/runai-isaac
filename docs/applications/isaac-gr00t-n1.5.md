# Isaac GR00T N1.5

This page is part of the sample applications guide. Follow [README](../../README.md) first and stop interactive workloads when finished.

(Optional) Create a docker image for [Isaac GR00T](https://github.com/NVIDIA/Isaac-GR00T/tree/n1.5-release) (N1.5):

```sh
docker build -f docker/isaac-gr00t-n1.5/Dockerfile . -t j3soon/runai-isaac-gr00t:n1.5
docker push j3soon/runai-isaac-gr00t:n1.5
```

> `docker/isaac-gr00t-n1.5/Dockerfile` follows the upstream [`n1.5-release` Dockerfile](https://github.com/NVIDIA/Isaac-GR00T/blob/n1.5-release/Dockerfile) and pins the exact upstream tag commit.

> Environment command:
>
> ```
> /run.sh "pip install jupyterlab" "jupyter lab --ip=0.0.0.0 --no-browser --allow-root --NotebookApp.base_url=/${RUNAI_PROJECT}/${RUNAI_JOB_NAME} --NotebookApp.token='' --notebook-dir=/"
> ```

## Run In Jupyter Lab

> Below is usage guide specific for this image.

Follow the [installation guide](https://github.com/NVIDIA/Isaac-GR00T/tree/n1.5-release#installation-guide):

```sh
git clone --recurse-submodules -b n1.5-release https://github.com/NVIDIA/Isaac-GR00T Isaac-GR00T-n1.5
cd Isaac-GR00T-n1.5
git lfs pull
```

Server mode:

```sh
export HF_HOME="$(pwd)/.cache/huggingface"
python scripts/inference_service.py --model-path nvidia/GR00T-N1.5-3B --server
```

TODO

Client mode (in another terminal):

```sh
export HF_HOME="$(pwd)/.cache/huggingface"
python scripts/inference_service.py --client
```

Follow the [upstream README](https://github.com/NVIDIA/Isaac-GR00T/tree/n1.5-release) for finetuning and embodiment-specific workflows.
