# Cosmos-Predict1

This page is part of the sample applications guide. Follow [README](../../README.md) first and stop interactive workloads when finished.

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
