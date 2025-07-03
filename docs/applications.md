# Sample Applications

## All-In-One and Extended Workspaces

1. (Optional) Create a docker image for [All-In-One](https://github.com/j3soon/dockerfile-fragments/tree/main/all-in-one) Workspace:

   ```sh
   # ubuntu 22.04 base
   docker build -f docker/all-in-one/Dockerfile . -t j3soon/runai-all-in-one
   docker push j3soon/runai-all-in-one
   # isaac-sim 4.5.0
   docker build -f docker/isaac-sim-ex/Dockerfile_4_5_0 . -t j3soon/runai-isaac-sim-ex:4.5.0
   docker push j3soon/runai-isaac-sim-ex:4.5.0
   # isaac-lab 2.1.0
   docker build -f docker/isaac-lab-ex/Dockerfile_2_1_0 . -t j3soon/runai-isaac-lab-ex:2.1.0
   docker push j3soon/runai-isaac-lab-ex:2.1.0
   ```

2. Launch a workspace using the docker image `j3soon/runai-all-in-one`

   Add 6 tools:

   ```
   Tools:
   - Jupyter
     Connection type: NodePort (Auto generate)
     Container port: 8888
   - TensorBoard
     Connection type: NodePort (Auto generate)
     Container port: 6006
   - VSCode
     Connection type: NodePort (Auto generate)
     Container port: 8080
   - noVNC
     Connection type: NodePort (Auto generate)
     Container port: 6080
   - TigerVNC
     Connection type: NodePort (Auto generate)
     Container port: 5900
   - SSH
     Connection type: NodePort (Auto generate)
     Container port: 22
   ```

   Environment command:

   ```
   /run.sh "/usr/bin/supervisord -n"
   ```

![](./assets/all-in-one-workspace.png)

To add these tools to your custom docker image, refer to [j3soon/dockerfile-fragments](https://github.com/j3soon/dockerfile-fragments).

## Isaac Sim

1. (Optional) Create a docker image for [Isaac Sim](https://docs.isaacsim.omniverse.nvidia.com/latest/index.html) following the [installation guide](https://docs.isaacsim.omniverse.nvidia.com/latest/installation/install_container.html):

   ```sh
   docker build -f docker/isaac-sim/Dockerfile_4_5_0 . -t j3soon/runai-isaac-sim:4.5.0
   docker push j3soon/runai-isaac-sim:4.5.0
   ```

2. Launch a workspace using the docker image `j3soon/runai-isaac-sim:4.5.0`

   Environment command:

   ```
   /run.sh "/isaac-sim/python.sh -m pip install jupyterlab" "/isaac-sim/python.sh /isaac-sim/kit/python/bin/jupyter lab --ip=0.0.0.0 --no-browser --allow-root --NotebookApp.base_url=/${RUNAI_PROJECT}/${RUNAI_JOB_NAME} --NotebookApp.token='' --notebook-dir=/"
   ```

3. Quick Test:

   ```sh
   /isaac-sim/python.sh /isaac-sim/standalone_examples/api/isaacsim.core.api/time_stepping.py
   # or
   /isaac-sim/python.sh /isaac-sim/standalone_examples/api/isaacsim.core.api/simulation_callbacks.py
   ```

If using `isaac-sim-ex` docker image, you can use the following command to launch interactive mode:

```sh
cd /isaac-sim
ACCEPT_EULA=Y ./runapp.sh
```

and then go to `Window > Examples > Robotics Examples`, in the `Robotics Examples` window, click `POLICY > Humanoid > LOAD`.

![](./assets/preview/isaac-sim-vnc.png)

## Isaac Lab

1. (Optional) Create a docker image for [Isaac Lab](https://isaac-sim.github.io/IsaacLab/main/index.html) following the [installation guide](https://isaac-sim.github.io/IsaacLab/main/source/deployment/docker.html):

   ```sh
   docker build -f docker/isaac-lab/Dockerfile_2_1_0 . -t j3soon/runai-isaac-lab:2.1.0
   docker push j3soon/runai-isaac-lab:2.1.0
   ```

2. Launch a workspace using the docker image `j3soon/runai-isaac-lab:2.1.0`

   Environment command:

   ```
   /run.sh "/isaac-sim/python.sh -m pip install jupyterlab" "/isaac-sim/python.sh /isaac-sim/kit/python/bin/jupyter lab --ip=0.0.0.0 --no-browser --allow-root --NotebookApp.base_url=/${RUNAI_PROJECT}/${RUNAI_JOB_NAME} --NotebookApp.token='' --notebook-dir=/"
   ```

3. [Quick test](https://isaac-sim.github.io/IsaacLab/main/source/deployment/docker.html#running-pre-built-isaac-lab-container):

   ```sh
   /workspace/isaaclab/isaaclab.sh -p scripts/tutorials/00_sim/log_time.py --headless
   # View the logs and press Ctrl+C to stop
   ```

4. [Train Cartpole](https://isaac-sim.github.io/IsaacLab/main/source/overview/reinforcement-learning/rl_existing_scripts.html):

   ```sh
   /workspace/isaaclab/isaaclab.sh -p scripts/reinforcement_learning/rl_games/train.py --task=Isaac-Cartpole-v0 --headless
   ```

If using `isaac-lab-ex` docker image, you can use the following command to launch interactive mode:

```sh
cd /workspace/isaaclab
./isaaclab.sh -p scripts/reinforcement_learning/rsl_rl/play.py --task Isaac-Velocity-Rough-H1-v0 --num_envs 32 --use_pretrained_checkpoint
```

You can change the `--num_envs` to a larger number such as `4096`.

![](./assets/preview/isaac-lab-vnc.png)

## Isaac GR00T

1. (Optional) Create a docker image for [Isaac GR00T](https://github.com/NVIDIA/Isaac-GR00T) following the [installation guide](https://github.com/NVIDIA/Isaac-GR00T):

   ```sh
   docker build -f docker/isaac-gr00t/Dockerfile . -t j3soon/runai-isaac-gr00t:n1
   docker push j3soon/runai-isaac-gr00t:n1
   ```

> TODO

## Cosmos-Predict1

1. (Optional) Create a docker image for [cosmos-predict1](https://github.com/nvidia-cosmos/cosmos-predict1) following the [installation guide](https://github.com/nvidia-cosmos/cosmos-predict1/blob/main/INSTALL.md):

   ```sh
   docker build -f docker/cosmos-predict1/Dockerfile . -t j3soon/runai-cosmos-predict1:latest
   docker push j3soon/runai-cosmos-predict1:latest
   ```

2. Launch a workspace using the docker image `j3soon/runai-cosmos-predict1`

   Environment command:

   ```
   /run.sh "pip install jupyterlab" "jupyter lab --ip=0.0.0.0 --no-browser --allow-root --NotebookApp.base_url=/${RUNAI_PROJECT}/${RUNAI_JOB_NAME} --NotebookApp.token='' --notebook-dir=/"
   ```

3. Run the following in Jupyter Lab terminal:

   ```sh
   cd /mnt/nfs/<YOUR_USERNAME>
   git clone https://github.com/nvidia-cosmos/cosmos-predict1.git
   cd cosmos-predict1
   CUDA_HOME=$CONDA_PREFIX PYTHONPATH=$(pwd) python scripts/test_environment.py
   # Check environment is set up successfully
   huggingface-cli login
   # And enter your Hugging Face token
   ```

4. Run the following [examples](https://github.com/nvidia-cosmos/cosmos-predict1?tab=readme-ov-file#getting-started):
   
   - [Inference with Diffusion-based Video2World](https://github.com/nvidia-cosmos/cosmos-predict1/blob/main/examples/inference_diffusion_video2world.md)

     Download checkpoints:
   
     ```sh
     CUDA_HOME=$CONDA_PREFIX PYTHONPATH=$(pwd) python scripts/download_diffusion_checkpoints.py --model_sizes 7B 14B --model_types Video2World --checkpoint_dir checkpoints
     # May need to accept multiple licenses and rerun the download script
     # The download should take a few hours to complete
     ```

     Run 7b model:

     ```sh
     # Assume running on 1 L40 GPU
     CUDA_HOME=$CONDA_PREFIX PYTHONPATH=$(pwd) python cosmos_predict1/diffusion/inference/video2world.py \
         --checkpoint_dir checkpoints \
         --diffusion_transformer_dir Cosmos-Predict1-7B-Video2World \
         --input_image_or_video_path assets/diffusion/video2world_input0.jpg \
         --num_input_frames 1 \
         --offload_text_encoder_model \
         --offload_prompt_upsampler \
         --offload_guardrail_models \
         --video_save_name diffusion-video2world-7b
     ```

     Run 14b model:

     ```sh
     # Assume running on 1 L40 GPU
     CUDA_HOME=$CONDA_PREFIX PYTHONPATH=$(pwd) python cosmos_predict1/diffusion/inference/video2world.py \
         --checkpoint_dir checkpoints \
         --diffusion_transformer_dir Cosmos-Predict1-14B-Video2World \
         --input_image_or_video_path assets/diffusion/video2world_input0.jpg \
         --num_input_frames 1 \
         --offload_tokenizer \
         --offload_diffusion_transformer \
         --offload_text_encoder_model \
         --offload_prompt_upsampler \
         --offload_guardrail_models \
         --video_save_name diffusion-video2world-14b
     ```

     Run 14b model across 8 GPUs:

     ```sh
     # Assume running on 8 L40 GPUs
     NUM_GPUS=8
     CUDA_HOME=$CONDA_PREFIX PYTHONPATH=$(pwd) torchrun --nproc_per_node=${NUM_GPUS} cosmos_predict1/diffusion/inference/video2world.py \
         --num_gpus ${NUM_GPUS} \
         --checkpoint_dir checkpoints \
         --diffusion_transformer_dir Cosmos-Predict1-14B-Video2World \
         --input_image_or_video_path assets/diffusion/video2world_input0.jpg \
         --num_input_frames 1 \
         --offload_tokenizer \
         --offload_diffusion_transformer \
         --offload_text_encoder_model \
         --offload_prompt_upsampler \
         --offload_guardrail_models \
         --video_save_name diffusion-video2world-14b
     ```
   
   - [Inference with Autoregressive-based Video2World](https://github.com/nvidia-cosmos/cosmos-predict1/blob/main/examples/inference_autoregressive_video2world.md)

     Download checkpoints:
   
     ```sh
     CUDA_HOME=$CONDA_PREFIX PYTHONPATH=$(pwd) python scripts/download_autoregressive_checkpoints.py --model_sizes 5B 13B --checkpoint_dir checkpoints
     # May need to accept multiple licenses and rerun the download script
     # The download should take a few hours to complete
     ```

     Run 13b model:
   
     ```sh
     # Assume running on 1 L40 GPU
     PROMPT="A video recorded from a moving vehicle's perspective, capturing roads, buildings, landscapes, and changing weather and lighting conditions."
     CUDA_HOME=$CONDA_PREFIX PYTHONPATH=$(pwd) python cosmos_predict1/autoregressive/inference/video2world.py \
         --checkpoint_dir checkpoints \
         --ar_model_dir Cosmos-Predict1-13B-Video2World \
         --input_type text_and_video \
         --input_image_or_video_path assets/autoregressive/input.mp4 \
         --prompt "${PROMPT}" \
         --top_p 0.7 \
         --temperature 1.0 \
         --offload_tokenizer \
         --offload_diffusion_decoder \
         --offload_ar_model \
         --offload_text_encoder_model \
         --offload_guardrail_models \
         --video_save_name autoregressive-video2world-13b
     ```

## Cosmos-Transfer1

Create a docker image for [cosmos-transfer1](https://github.com/nvidia-cosmos/cosmos-transfer1) following the [installation guide](https://github.com/nvidia-cosmos/cosmos-transfer1/blob/main/INSTALL.md):

```sh
docker build -f docker/cosmos-transfer1/Dockerfile . -t j3soon/runai-cosmos-transfer1:latest
docker push j3soon/runai-cosmos-transfer1:latest
```

```sh
CUDA_HOME=$CONDA_PREFIX PYTHONPATH=$(pwd) python scripts/test_environment.py
```

> TODO
