# Troubleshooting

If you encountered any of the following errors, contact the cluster admin for help.

## NVLink Error in a Single Node

If a workload history shows `UnexpectedAdmissionError` event with the following:

```
Allocate failed due to device plugin GetPreferredAllocation rpc failed with err: rpc error: code = Unknown desc = error getting list of preferred allocation devices: unable to get device link information: error getting NVLink for devices (3, 0): failed to get nvlink remote pci info: failed to get nvlink state: GPU is lost, which is unexpected
```

There's a high chance that the assigned node has faulty GPU. Scroll down to a `Bound` event and check the assigned node:

```
Pod bound successfully to node <NODE_NAME>
```

and report to admin.

**Admin:** Isolate the node:

```sh
NODE_NAME="<TARGET_NODE>"

kubectl label node "${NODE_NAME}" j3soon/runai-node-pool=dev --overwrite
```

After the node has been isolated in the `dev` node pool, use the [Run:ai REST API node-affinity field](https://run-ai-docs.nvidia.com/api/api-guides/using-node-affinity-via-api) to launch a preemptible 8-GPU diagnostic workspace on its exact hostname. The CLI does not expose general required node affinity: `--node-type` requires a separate `run.ai/type` label, while `--required-pod-topology-key` groups workload pods and does not select a hostname. The REST API can directly match the built-in `kubernetes.io/hostname` label.

This requires `curl`, `jq`, and an authenticated Run:ai CLI session:

```sh
export SSL_CERT_FILE="$HOME/.runai/certs/root-ca.crt"
NODE_NAME="<TARGET_NODE>"
WORKSPACE_NAME=nvlink-diagnostic
NFS_NAME="<NFS_NAME>"
NFS_SERVER="<NFS_SERVER>"
NFS_PATH="<NFS_PATH>"
NFS_MOUNT_PATH=/mnt/nfs

RUNAI_CONFIG=$(runai config describe --json)
RUNAI_URL=$(printf '%s' "${RUNAI_CONFIG}" | jq -r '.cluster.domain')
RUNAI_PROJECT=$(printf '%s' "${RUNAI_CONFIG}" | jq -r '.cluster.project.name')
RUNAI_PROJECT_ID=$(printf '%s' "${RUNAI_CONFIG}" | jq -r '.cluster.project.id')
RUNAI_CLUSTER_ID=$(printf '%s' "${RUNAI_CONFIG}" | jq -r '.cluster.uuid')
RUNAI_API_TOKEN=$(runai auth get-token --output plaintext)

jq -n \
  --arg name "${WORKSPACE_NAME}" \
  --arg projectId "${RUNAI_PROJECT_ID}" \
  --arg clusterId "${RUNAI_CLUSTER_ID}" \
  --arg nodeName "${NODE_NAME}" \
  --arg nfsName "${NFS_NAME}" \
  --arg nfsServer "${NFS_SERVER}" \
  --arg nfsPath "${NFS_PATH}" \
  --arg nfsMountPath "${NFS_MOUNT_PATH}" \
  --arg args 'jupyter lab --allow-root --ip=0.0.0.0 --no-browser --notebook-dir=/ --NotebookApp.base_url=/${RUNAI_PROJECT}/${RUNAI_JOB_NAME} --NotebookApp.token=' \
  '{
    name: $name,
    projectId: $projectId,
    clusterId: $clusterId,
    spec: {
      args: $args,
      compute: {gpuDevicesRequest: 8, largeShmRequest: true},
      exposedUrls: [{container: 8888}],
      image: "j3soon/hpc-samples:nvhpc-25.7-devel-cuda12.9-ubuntu24.04",
      imagePullPolicy: "Always",
      nodeAffinityRequired: {
        nodeSelectorTerms: [{
          matchExpressions: [{
            key: "kubernetes.io/hostname",
            operator: "In",
            values: [$nodeName]
          }]
        }]
      },
      nodePools: ["dev"],
      priorityClass: "interactive-preemptible",
      restartPolicy: "Always",
      security: {uidGidSource: "fromTheImage"},
      storage: {
        nfs: [{
          name: $nfsName,
          server: $nfsServer,
          path: $nfsPath,
          mountPath: $nfsMountPath,
          readOnly: false
        }]
      },
      workingDir: "/"
    }
  }' |
curl --silent --show-error --fail-with-body \
  --cacert "${SSL_CERT_FILE}" \
  --request POST \
  --header "Authorization: Bearer ${RUNAI_API_TOKEN}" \
  --header 'Content-Type: application/json' \
  --data-binary @- \
  "${RUNAI_URL}/api/v1/workloads/workspaces" |
jq

unset RUNAI_API_TOKEN RUNAI_CONFIG
```

The required `kubernetes.io/hostname` affinity restricts the workspace to `NODE_NAME`. The `interactive-preemptible` priority allows it to use the `dev` pool when the project has no non-preemptible GPU quota there. The named NFS export is mounted read-write at `/mnt/nfs`.

If exact hostname selection is unnecessary, use the CLI to target the `dev` node pool without specifying a node:

```sh
export SSL_CERT_FILE="$HOME/.runai/certs/root-ca.crt"
RUNAI_PROJECT="<YOUR_PROJECT>"
WORKSPACE_NAME=nvlink-diagnostic
NFS_SERVER="<NFS_SERVER>"
NFS_PATH="<NFS_PATH>"
NFS_MOUNT_PATH=/mnt/nfs

runai workspace submit "${WORKSPACE_NAME}" \
  --project "${RUNAI_PROJECT}" \
  --image j3soon/hpc-samples:nvhpc-25.7-devel-cuda12.9-ubuntu24.04 \
  --image-pull-policy Always \
  --node-pools dev \
  --gpu-devices-request 8 \
  --preemptible \
  --large-shm \
  --user-group-source fromTheImage \
  --nfs "path=${NFS_PATH},server=${NFS_SERVER},mountpath=${NFS_MOUNT_PATH},readwrite" \
  --external-url container=8888 \
  -- jupyter lab \
    --allow-root \
    --ip=0.0.0.0 \
    --no-browser \
    --notebook-dir=/ \
    --NotebookApp.base_url='/${RUNAI_PROJECT}/${RUNAI_JOB_NAME}' \
    --NotebookApp.token=''
```

This CLI command may schedule on any suitable node in `dev`. Its `--nfs` syntax does not accept a volume name, but it mounts the same server, export path, and target directory.

Check Event History for a `Bound` event and the logs for the Jupyter Lab startup message. For the REST submission, confirm the event says `Pod bound successfully to node ${NODE_NAME}`:

```sh
runai workspace list --project "${RUNAI_PROJECT}"
runai workspace describe "${WORKSPACE_NAME}" \
  --project "${RUNAI_PROJECT}" \
  --events \
  --pods
runai workspace logs "${WORKSPACE_NAME}" \
  --project "${RUNAI_PROJECT}" \
  --tail 50
runai workspace exec "${WORKSPACE_NAME}" \
  --project "${RUNAI_PROJECT}" \
  -- findmnt -T "${NFS_MOUNT_PATH}"
runai workspace exec "${WORKSPACE_NAME}" \
  --project "${RUNAI_PROJECT}" \
  -- python3 -c "import pathlib,tempfile; d=pathlib.Path('${NFS_MOUNT_PATH}'); f=tempfile.NamedTemporaryFile(mode='w+',prefix='.runai-nfs-check-',dir=d,delete=True); f.write('nfs-ok'); f.flush(); f.seek(0); assert f.read() == 'nfs-ok'; print('NFS read/write OK:', d); f.close()"
```

Then select the workspace in the Run:ai UI and use `CONNECT > Jupyter`.

Open a terminal in the launched JupyterLab and run the NVBandwidth test. Its combined output is also saved to the NFS mount:

```sh
mkdir -p /mnt/nfs/j3soon
cd /mnt/nfs/j3soon
git clone https://github.com/j3soon/hpc-samples
./hpc-samples/src/scripts/intranode-comm-test.sh
```

Delete the workspace after troubleshooting to release all eight GPUs:

```sh
runai workspace delete "${WORKSPACE_NAME}" --project "${RUNAI_PROJECT}"
```

## GPU Uncorrectable ECC error

```
RuntimeError: CUDA error: uncorrectable ECC error encountered
CUDA kernel errors might be asynchronously reported at some other API call, so the stacktrace below might be incorrect.
For debugging consider passing CUDA_LAUNCH_BLOCKING=1
Compile with `TORCH_USE_CUDA_DSA` to enable device-side assertions.
```

The error messages should also report the GPU ID with ECC error.

**Admin:** Can potentially be fixed with power-cycling. Need further investigation.

## Silent GPU FLOPS Degradation

**Admin:** This usually will not result in an error, use `gpu-burn` to quickly compare the FLOPS against a health node.

## Node with Memory and Disk pressure

```
Memory pressure: Node memory is low.
Disk pressure: Disk capacity is low.
Node not ready.
```

**Admin:** Can potentially be fixed with power-cycling. Need further investigation.
