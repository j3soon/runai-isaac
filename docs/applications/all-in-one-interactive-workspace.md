# All-In-One Interactive Workspace

This page is part of the sample applications guide. Follow [README](../../README.md) first and stop interactive workloads when finished.

> You can skip this section if you plan to only submit batch workloads, such as non-interactive Isaac Sim and Isaac Lab training tasks.

We take the All-In-One workspace as a comprehensive example that includes multiple tools for development and debugging.

1. (Optional) Create a docker image for [All-In-One Workspace](https://github.com/j3soon/runai-isaac/blob/main/docker/all-in-one/Dockerfile):

   ```sh
   docker build -t j3soon/runai-all-in-one -f docker/all-in-one/Dockerfile .
   docker push j3soon/runai-all-in-one
   ```

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
     <YOUR_USERNAME>-all-in-one
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
       j3soon/runai-all-in-one
       ```
     - Image pull policy
       ```
       Always pull the image from the registry
       ```
   - Tools
     - Tool
       ```
       Jupyter
       Connection type: NodePort (Auto generate)
       Container port: 8888
       ```
     - Tool
       ```
       TensorBoard
       Connection type: NodePort (Auto generate)
       Container port: 6006
       ```
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
       ```
       Custom - TigerVNC
       Connection type: NodePort (Auto generate)
       Container port: 5900
       ```
     - Tool
       ```
       Custom - SSH
       Connection type: NodePort (Auto generate)
       Container port: 22
       ```
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

   ![](../assets/all-in-one-workspace.png)

3. Create a new GPU workload based on the environment.

   Go to `Workload manager > Workloads` and click `+ NEW WORKLOAD > Workspace`.

   Fill in the following fields:

   - Workspace name
     ```
     <YOUR_USERNAME>-all-in-one-test
     ```

     and click `CONTINUE`.

   - Environment
     - Select the environment for your workload:
       ```
       <YOUR_USERNAME>-all-in-one
       ```
     - (Optional) Set the connection for your tool(s):
       ```
       Tool Access: Set to Specific user(s)
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

4. Connect to the tools.

   In `Workload manager > Workloads`, select the workload you just created and click `CONNECT` to access various tools.

   > When using multiple tools within a single environment, the tool ports may be randomly reordered due to a Run:ai bug (which I believe is fixed in the latest version). See the [developer notes](../developer-notes.md#be-aware-that-runai-tool-urls-may-reorder-randomly) for more details.
   >
   > In this case, you can still identify the correct tool port by trial-and-error. For admins, use `kubectl get services -n runai-<PROJECT_NAME>` to bypass trial-and-error.

5. (Optional) Test every tools.

   Open all 6 tools in the browser. You should notice that the link ports are not the same in those inside the container. For example, SSH inside the container is `22` port, but the link port may be `33333`. This is because the ports are exposed through K8s `NodePort`.

   Jupyter Lab, web-based VSCode, and TensorBoard are straightforward to use. For applications that require GUI (such as Isaac Sim and Isaac Lab interactive mode), you can use the noVNC tool. It should show the GUI, and you'll want to set the `Scaling Mode` to `Remote Resizing`. noVNC is the recommended tool for GUI applications, however you can also use VNC viewers to connect directly to the VNC port. Last but not least, the SSH port can connect to the container, and can also be used for local VSCode `Remote Development` feature.

   ![](../assets/all-in-one-workspace-novnc-remote-resizing.png)

6. Delete the workload.

   Go to `Workload manager > Workloads` and select the workload you just created and click `DELETE`. Please always `STOP` or `DELETE` the workload after you are done with the task to allow maximum resource utilization.

Always store your data under the `/mnt/nfs/<YOUR_USERNAME>` directory to ensure your results persist even after the container is terminated.

To add these tools to your custom docker image, refer to [j3soon/dockerfile-fragments](https://github.com/j3soon/dockerfile-fragments).

Before moving on, make sure you are familiar with the noVNC tool, this is required to access the following GUI applications. In addition, if planning to use interactive GUI for the following applications, the Environment Template should follow the `all-in-one` template, such as the command should use the `/run.sh "/usr/bin/supervisord -n"` command instead of those used in non-interactive jobs.

> Note that for the following applications, docker images without the `-ex` suffix are for non-interactive jobs, and docker images with the `-ex` suffix are for interactive jobs. The Environment Template are also different for these two types of jobs. If you encountered errors such as unable to access the VNC desktop, inspect the `all-in-one` case carefully, and make sure you have grasped the concept of the `all-in-one` docker image and Environment Template.

> Moving forward, you can only expose the ports of the tools you need, and hide the rest to reduce the impact of the tool reordering bug. For example, if you only need noVNC, you can expose only port 6080 in your Environment Template. This will make it easier to identify which port corresponds to which tool, since there will be fewer ports to check.
