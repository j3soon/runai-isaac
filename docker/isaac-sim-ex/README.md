# Isaac Sim (Extended) Interactive Workspace

This page is part of the sample applications guide. Follow [README](../../README.md) first and stop interactive workloads when finished.

We take Isaac Sim interactive mode as an example for GUI-based simulation development and debugging.

1. (Optional) Create a docker image for [Isaac Sim Extended Workspace](https://github.com/j3soon/runai-isaac/blob/main/docker/isaac-sim-ex/Dockerfile_4_5_0):

   ```sh
   docker build -t j3soon/runai-isaac-sim-ex:4.5.0 -f docker/isaac-sim-ex/Dockerfile_4_5_0 .
   docker push j3soon/runai-isaac-sim-ex:4.5.0
   docker build -t j3soon/runai-isaac-sim-ex:5.0.0 -f docker/isaac-sim-ex/Dockerfile_5_0_0 .
   docker push j3soon/runai-isaac-sim-ex:5.0.0
   docker build -t j3soon/runai-isaac-sim-ex:5.1.0 -f docker/isaac-sim-ex/Dockerfile_5_1_0 .
   docker push j3soon/runai-isaac-sim-ex:5.1.0
   docker build -t j3soon/runai-isaac-sim-ex:6.0.0 -f docker/isaac-sim-ex/Dockerfile_6_0_0 .
   docker push j3soon/runai-isaac-sim-ex:6.0.0
   ```

   > This step is optional since we provide pre-built docker images on Docker Hub.

   For the ROS 2 Jazzy variant, see [Isaac Sim (Extended) with ROS 2](../isaac-sim-ex-ros2/README.md).

2. Create a new environment for your docker image.

   Go to `Workload manager > Assets > Environments` and click `+ NEW ENVIRONMENT`.

   Fill in the following fields:

   - Scope
     ```
     runai/runai-cluster/<YOUR_LAB>/<YOUR_PROJECT>
     ```
   - Environment name
     ```
     <YOUR_USERNAME>-isaac-sim-ex
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
       j3soon/runai-isaac-sim-ex:4.5.0
       ```
     - Image pull policy
       ```
       Always pull the image from the registry
       ```
   - Tools
     - Tool
       ```
       VSCode
       Connection type: NodePort (Auto generate)
       Container port: 8080
       ```
     - Tool
       ```
       Custom - noVNC
       Connection type: NodePort (Auto generate)
       Container port: 6080
       ```
     - Tool
       (Optionally [expose more ports](../all-in-one/README.md) for other tools if needed.)
   - Runtime settings
     - Command
       ```
       /run.sh "/usr/bin/supervisord -n"
       ```
     - Arguments: (Keep empty)
   - Security
     - Set where the UID, GID, and supplementary groups for the container should be taken from
       ```
       From the image
       ```
       > In newer versions of Run:ai, the default value may be `From the IdP token`.

   and then click `CREATE ENVIRONMENT`.

   > Note that the Environment Template should follow the `all-in-one` template, using the `/run.sh "/usr/bin/supervisord -n"` command instead of those used in non-interactive jobs.

3. Create a new GPU workload based on the environment.

   Go to `Workload manager > Workloads` and click `+ NEW WORKLOAD > Workspace`.

   Fill in the following fields:

   - Workspace name
     ```
     <YOUR_USERNAME>-isaac-sim-ex-test
     ```

     and click `CONTINUE`.

   - Environment
     - Select the environment for your workload:
       ```
       <YOUR_USERNAME>-isaac-sim-ex
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

4. Connect to the noVNC tool.

   In `Workload manager > Workloads`, select the workload you just created and click `CONNECT > noVNC`.

   You should see the GUI, and you'll want to set the `Scaling Mode` to `Remote Resizing`.

5. Launch Isaac Sim interactive mode.

   In the noVNC desktop, open a terminal and run:

   ```sh
   cd /isaac-sim
   ACCEPT_EULA=Y ./runapp.sh
   ```

   Then go to `Window > Examples > Robotics Examples`, in the `Robotics Examples` window, click `POLICY > Humanoid > LOAD`.

   ![](../../docs/assets/preview/isaac-sim-vnc.png)

6. Delete the workload.

   Go to `Workload manager > Workloads` and select the workload you just created and click `DELETE`. Please always `STOP` or `DELETE` the workload after you are done with the task to allow maximum resource utilization.

Always store your data under the `/mnt/nfs/<YOUR_USERNAME>` directory to ensure your results persist even after the container is terminated.
