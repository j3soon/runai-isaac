# Install Run:ai

Follow [the self-hosted installation guide](https://run-ai-docs.nvidia.com/guides/self-hosted-installation/installation).

Note that K8s with GPU operator can be easily installed using [NVIDIA Cloud Native Stack](https://github.com/NVIDIA/cloud-native-stack).

> Tested on Run:ai v2.20.29.

## K8s Patches

### Workload Cannot Launch Successfully

Apply the following patch:

```
kubectl patch RunaiConfig runai -n runai --type=merge -p '{"spec":{"workload-controller":{"externalAuthUrlEnabled": false}}}'
```

> Details to be confirmed.

### Run:ai Dashboard Connection Issue

After launching some workloads, the Run:ai Dashboard may be unreachable. This is due to a known issue with the Ingress controller.

```sh
kubectl get pod -A | grep ingress
kubectl delete pods -n ingress-nginx ingress-nginx-controller-xxxxxxxxxx-xxxxx
kubectl logs -n ingress-nginx ingress-nginx-controller-xxxxxxxxxx-xxxxx | grep alert
```

Observe the following error:

```
[alert] 48#48: socketpair() failed while spawning "worker process" (24: No file descriptors available)
```

This issue commonly occurs on machines with many CPU cores, as the Ingress controller divides the total number of available file descriptors by the number of cores for each worker process. With many cores, this division results in too few file descriptors per worker, causing them to run out of available descriptors.

Apply the following patch:

```sh
helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.config.worker-processes="4" \
  --set controller.config.worker-connections="10240" \
  --set controller.config.worker-rlimit-nofile="65536"
```

References:

- [Ingress-controller exited with fatal code 2 and cannot be respawned](https://github.com/kubernetes/ingress-nginx/issues/6141)
- [num of worker_processes set to max num of cores of cluster node with cgroups-v2](https://github.com/kubernetes/ingress-nginx/issues/11518)
- [关于nginx-ingress-controller中worker参数的差异分析](https://zhuanlan.zhihu.com/p/359700475)
- [追踪nginx ingress最大打开文件数问题](https://ieevee.com/tech/2019/09/29/ulimit.html)

## Run:ai Configuration

### Resources

Under the [Resources](https://run-ai-docs.nvidia.com/guides/platform-management/aiinitiatives/resources) section, make sure you have correctly configured the `Clusters` and `Nodes` section.

For the [`Nodes pools`](https://run-ai-docs.nvidia.com/guides/platform-management/aiinitiatives/resources/node-pools) section, add the following pools:

1. Production pool for nodes that are stable.
   ```
   Node pool name: prod
   Node pool label:
     Key: j3soon/runai-node-pool
     Value: prod
   ```
2. Development pool for nodes that are reported to be unstable and under admin investigation.
   ```
   Node pool name: dev
   Node pool label:
     Key: j3soon/runai-node-pool
     Value: dev
   ```

Keep both of the `GPU placement strategy` as default `Bin-pack` to prevent GPU resource fragmentation.

The creation of node pools is not required, but it is often useful for the cluster admin to isolate unstable nodes. If you have heterogeneous hardware environment, you can create more node pools to [isolate different hardwares](https://run-ai-docs.nvidia.com/guides/platform-management/aiinitiatives/adapting-ai-initiatives#grouping-your-resources).

Tag each of the nodes with the corresponding node pool label. For an example:

```sh
kubectl label node ovx01 j3soon/runai-node-pool=prod
kubectl label node ovx02 j3soon/runai-node-pool=prod
kubectl label node ovx03 j3soon/runai-node-pool=prod
kubectl label node ovx04 j3soon/runai-node-pool=dev # assume ovx04 is unstable
```

Refresh the web page of the Run:ai Dashboard to confirm the changes.

### Organization

Under the Organization section, Run:ai has [2 levels of organization](https://run-ai-docs.nvidia.com/guides/platform-management/aiinitiatives/adapting-ai-initiatives#scopes-in-an-organization): Department and Project. Departments can contain multiple Projects, and resources can be allocated at both levels.

In our case, we have a single cluster where all users are trusted and cooperative individuals who share computing resources. Therefore, we won't limit resources for each user by default for ease of use and to maximize usage of the available resources.

1. At the department level, we create two departments corresponding to our two university labs.

   ```
   Department name: lab1
   Quota management:
     Allow department to go over quota: False
     Node Pools
       Order of priority: 1
       Node pool: prod
       GPU devices: 100
   -----
   Department name: lab2
   Quota management:
     Allow department to go over quota: False
     Node Pools
       Order of priority: 1
       Node pool: prod
       GPU devices: 100
   ```

   > The GUI has maximum 100 GPUs, if your cluster have more than 100 GPUs, may need to look into a way to increase the limit.

   We will use departments to isolate shared NFS storage among university labs for data sharing. Each department can use all cluster resources since we don't enforce quotas. With trusted and cooperative users, we don't need to [configure over-quota policies](https://run-ai-docs.nvidia.com/guides/platform-management/runai-scheduler/scheduling/how-the-scheduler-works#reclaim-preemption-between-projects-and-departments), saving everyone from the hassle of making their workloads preemptible.

2. At the project level, we create a default project for each lab.

   ```
   Department: runai/runai-cluster/lab1
   Project name: lab1-default-project
   Quota management:
     Node Pools
       Order of priority: 1
       Node pool: prod
       GPU devices: 100
       Over quota: Disabled
   -----
   Department: runai/runai-cluster/lab2
   Project name: lab2-default-project
   Quota management:
     Node Pools
       Order of priority: 1
       Node pool: prod
       GPU devices: 100
       Over quota: Disabled
   ```

   Although we currently have only one project per department, we can use the project level to guarantee GPU resources in the future for projects with near-term deadlines. This will require decreasing the GPU resources for departments and the default projects.

> Note: If you forget to set the `Order of priority` to 1, the workloads sometimes seem to queue indefinitely even if there are GPUs available.

### Access

In this Run:ai version, we cannot create or edit custom roles. The most suitable [default role](https://run-ai-docs.nvidia.com/guides/infrastructure-setup/authentication/roles) for users is `L2 researcher`, which provides basic access to submit and manage workloads. However, since we have trusted users whom we want to be able to create custom Environments and Templates, we assign additional permissions to them by adding them to the `Environment administrator` and `Template administrator` roles.

For each user, create an account with a unique ID and assign the following roles:

```
Role: L2 researcher
Scope: (default project under the user's department)
---
Role: Environment administrator
Scope: (default project under the user's department)
---
Role: Template administrator
Scope: (default project under the user's department)
```

We don't really want the users to be able to see other department's analytics, but this cannot be achieved without sacrificing the ability to create custom Environments and Templates.

To simplify the user creation process, we can use [the Runai API](https://api-docs.run.ai/latest) to create users and assign roles (i.e., access rules).

1. Create a new Application under Applications section.

   ```
   Application name: admin-cli
   ```

   and save the `Client ID` and `Client secret` to the `secrets/env.sh` file.

   ```
   export RUNAI_URL="https://runai.local"
   export RUNAI_CLIENT_ID="<YOUR_APPLICATION_NAME>"
   export RUNAI_CLIENT_SECRET="<YOUR_APPLICATION_SECRET>"
   export STORAGE_NODE_IP="<STORAGE_NODE_IP>"
   ```

2. Add an access rule for the application.

   ```
   Role: System administrator
   Scope: runai
   ```

3. Add a new user:

   ```sh
   source secrets/env.sh
   sudo apt-get update && sudo apt-get install curl jq
   scripts/admin/create_user.sh <USER_EMAIL> <PROJECT_NAME>
   ```

> The Run:ai GUI also uses the API, so if you have any issues when using the API, you can inspect the `Network` tab in your browser's developer tools to see the actual API requests and responses. This can help debug API usage issues.

### Workload manager

Since users are trusted to create custom Environments and Templates by themselves, we now only need to create `Compute resources` and `Data sources` for them.

1. Create 0~8 GPU compute resources.

   ```sh
   source secrets/env.sh
   scripts/admin/create_compute.sh
   ```

2. Create data sources for the shared NFS storages under `Assets > Data sources` and select `NFS` as the type.

   > Assuming a large NFS storage has been set up on the storage node, with FTPS (we don't use SFTP since we don't want the users to have SSH privileges) configured to allow secure user uploads and downloads. Instructions for setting up NFS and FTPS will be provided later.

   ```
   Scope: runai/runai-cluster/lab1
   Data source name: lab1-nfs
   NFS server (host name or host IP): <STORAGE_NODE_IP>
   Mount path: /mnt/nfs/lab1
   Container path: /mnt/nfs
   ---
   Scope: runai/runai-cluster/lab2
   Data source name: lab2-nfs
   NFS server (host name or host IP): <STORAGE_NODE_IP>
   Mount path: /mnt/nfs/lab2
   Container path: /mnt/nfs
   ```

## Miscellaneous

Some cluster admin notes for future reference.

### Preemption

The default K8s PriorityClass is set as follows:

```
# kubectl get priorityclass -A
NAME                      VALUE
build                     100
inference                 125
interactive-preemptible   75
runai-critical            1000000000
runai-engine-critical     1000000000
train                     50
train-critical            60
train-high                55
```

More details can be found in the documentation pages: [Workload Priority Control](https://run-ai-docs.nvidia.com/guides/platform-management/runai-scheduler/scheduling/workload-priority-class-control) and [Priority and Preemption](https://run-ai-docs.nvidia.com/guides/platform-management/runai-scheduler/scheduling/concepts-and-principles#priority-and-preemption).

We want to disable preemption by setting the priority class of all workloads to 0. This also allows side-by-side usage of [j3soon/omni-farm-isaac](https://github.com/j3soon/omni-farm-isaac), where the workloads have default priority values of 0.

However, it seems like the priority class is not assigned to the K8s pods as expected. All K8s pods priority seems to be 0, which isn't the expected behavior, but is what we want.

For `Workspace` type workloads:

```sh
# kubectl get pods -n runai-lab1-default-project test-0-0 -o yaml
apiVersion: v1
kind: Pod
metadata:
  ...
  labels:
    ...
    priorityClassName: build
    ...
spec:
  ...
  preemptionPolicy: PreemptLowerPriority
  priority: 0
  ...
```

For `Training` type workloads:

```sh
# kubectl get pods -n runai-lab1-default-project test-0-0 -o yaml
apiVersion: v1
kind: Pod
...
spec:
  ...
  preemptionPolicy: PreemptLowerPriority
  priority: 0
  ...
```

### Backoff Limit

The minimal backoff limit that can be set on the GUI is 1.

```
# kubectl describe RunaiJob -n runai-lab1-default-project | grep "Backoff Limit:"
  Backoff Limit:                                1
  Backoff Limit:                                6
```

In the future, we want to change the minimal backoff limit to 0. When a training job fails after running for several days, users may prefer to manually resume the job using a different script rather than having it automatically retry. Automatic retries could potentially overwrite existing checkpoints and waste compute resources.

While well-designed training workloads should support preemption and automatic checkpoint resumption, we have decided not to impose these requirements on users. This allows them to work in a non-preemptive environment without the burden of implementing resumption capabilities.

## More Information

For more information on how to use Run:ai, please refer to the [Run:ai Documentation](https://run-ai-docs.nvidia.com/) and [CLI Reference](https://run-ai-docs.nvidia.com/guides/reference/cli).
