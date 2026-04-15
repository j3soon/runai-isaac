# Isaac Lab Headless Workspace

This page is part of the sample applications guide. Follow [README](../../README.md) first and stop interactive workloads when finished.

We take [Isaac Lab](https://isaac-sim.github.io/IsaacLab/main/index.html) headless training as an example for reinforcement learning workloads that don't require GUI interaction.

1. (Optional) Create a docker image for Isaac Lab Workspace following the [docker guide](https://isaac-sim.github.io/IsaacLab/main/source/deployment/docker.html):
   ```sh
   docker build -t j3soon/runai-isaac-lab:2.1.0 -f docker/isaac-lab/Dockerfile_2_1_0 .
   docker push j3soon/runai-isaac-lab:2.1.0
   docker build -t j3soon/runai-isaac-lab:2.2.0 -f docker/isaac-lab/Dockerfile_2_2_0 .
   docker push j3soon/runai-isaac-lab:2.2.0
   docker build -t j3soon/runai-isaac-lab:2.3.2 -f docker/isaac-lab/Dockerfile_2_3_2 .
   docker push j3soon/runai-isaac-lab:2.3.2
   ```

   Available Dockerfiles: [`docker/isaac-lab/Dockerfile_2_1_0`](../../docker/isaac-lab/Dockerfile_2_1_0), [`docker/isaac-lab/Dockerfile_2_2_0`](../../docker/isaac-lab/Dockerfile_2_2_0), [`docker/isaac-lab/Dockerfile_2_3_2`](../../docker/isaac-lab/Dockerfile_2_3_2).

   > This step is optional since we provide pre-built docker images on Docker Hub.

2. Create a new environment for your docker image.

   Go to `Workload manager > Assets > Environments` and click `+ NEW ENVIRONMENT`.

   Fill in the following fields:

   - Scope
     ```
     runai/runai-cluster/<YOUR_LAB>/<YOUR_PROJECT>
     ```
   - Environment name
     ```
     <YOUR_USERNAME>-isaac-lab
     ```
   - Workload architecture & type
     - Select the type of workload that can use this environment:
       ```
       Workspace: ✅ (Checked)
       Training: ⬜ (Unchecked)
       Inference: ⬜ (Unchecked)
       ```
   - Image
     - Image URL
       ```
       j3soon/runai-isaac-lab:2.3.2
       ```
     - Image pull policy
       ```
       Always pull the image from the registry
       ```
   - Runtime settings
     - Command
       ```
       /run.sh "/workspace/isaaclab/isaaclab.sh -p -u scripts/reinforcement_learning/rl_games/train.py --task=Isaac-Cartpole-v0 --headless"
       ```
       > The `-u` flag is required for correct logging by setting unbuffered mode.
     - Arguments: (Keep empty)
   - Security
     - Set where the UID, GID, and supplementary groups for the container should be taken from
       ```
       From the image
       ```
       > In newer versions of Run:ai, the default value may be `From the IdP token`.

   and then click `CREATE ENVIRONMENT`.

3. Create a new GPU workload based on the environment.

   Go to `Workload manager > Workloads` and click `+ NEW WORKLOAD > Workspace`.

   Fill in the following fields:

   - Workspace name
     ```
     <YOUR_USERNAME>-isaac-lab-test
     ```

     and click `CONTINUE`.

   - Environment
     - Select the environment for your workload:
       ```
       <YOUR_USERNAME>-isaac-lab
       ```
   - Compute resource
     - Select the node resources needed to run your workload:
       ```
       gpu-x1
       ```
   - Data sources
     - Select the data sources your workload needs to access:
       ```
       <YOUR_LAB>-nfs
       ```
   - General
     - Set the backoff limit before workload failure:
       ```
       Attempts: 0
       ```

   and then click `CREATE WORKSPACE`.

4. Wait for the workload to finish. Inspect the logs and delete the workload after the task is completed.

As you can see, this example only logs results and does not save any checkpoints or output files. For real-world workloads, make sure to place your code in the `/mnt/nfs/<YOUR_USERNAME>` directory and save any checkpoints or outputs there. This ensures your results are preserved even after the container is terminated.

Basically, you'll want to store your modified Isaac Lab codebase under the `/mnt/nfs/<YOUR_USERNAME>` directory and run the workload using the scripts from `/mnt/nfs/<YOUR_USERNAME>`.
