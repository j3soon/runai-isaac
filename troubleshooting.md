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

Despite the wording, this is usually **not** an NVLink-fabric fault. The device plugin probes
NVLink state during `GetPreferredAllocation` on every node, including nodes whose GPUs have no
NVLink at all; on a healthy such node the probe returns "not supported" cleanly. `GPU is lost`
means the named device had dropped off the PCIe bus at that moment, and NVLink is only where the
probe happened to fail first. Confirm which it is from the node itself: `nvidia-smi topo -m`
showing only `PIX`/`SYS` links and `nvidia-smi topo -p2p n` returning `NS` for every pair means
the hardware has no NVLink to fault, so treat the report as a bus-drop.

The condition can also clear on its own across a reboot or power-cycle, in which case the node
admits a full-GPU workload again. Do not read that as the node being healthy: the comms diagnostic
below passed completely on a node whose GPU then died under sustained load. Record when the fault
was observed and whether the node was restarted in between, and run `gpu-burn` before concluding
the report was spurious.

**Admin:** The comms diagnostic does not detect this fault. On a node that had reported
`GPU is lost`, nvbandwidth's 86 test groups, nccl-tests, aggregate ECC counters, remapped-row
state and PCIe link width were all clean with all eight GPUs enumerated; a 300-second `gpu-burn`
then dropped one GPU out of NVML and it did not return when the load ended. Confirm the drop with:

```sh
nvidia-smi --query-gpu=index --format=csv,noheader | wc -l   # fewer than expected
ls /proc/driver/nvidia/gpus/ | wc -l                          # still the full count
```

The kernel keeps the PCI device node after NVML loses the device, and that split is what makes the
device plugin emit `GPU is lost`. Confirm the fault and its layer from the node's own kernel log,
which names the UUID and board serial outright:

```sh
sudo dmesg -T | grep -iE "xid|fallen off the bus|link down|card not present|aer_layer"
```

```
NVRM: Xid (PCI:0000:1c:00): 79, pid=..., name=gpu_burn, GPU has fallen off the bus.
pcieport 0000:18:03.0: pciehp: Slot(3): Link Down
pcieport 0000:18:03.0: AER: aer_layer=Physical Layer, aer_agent=Receiver ID
```

`Xid 79` with a Physical Layer AER is conclusive hardware evidence — reseat the card and riser, then
RMA against the board serial. `Xid 154` (`Node Reboot Required`) fires on **every** GPU on the node,
so reboot before returning even a partially-working node to service. Record the
`nvidia-smi --query-gpu=index,uuid,serial,pci.bus_id --format=csv` map *before* loading the node and
identify the failed GPU by UUID or serial — the survivors renumber when one drops, so indices are
ambiguous across the failure. Note also that `gpu-burn`'s closing `GPU n: OK` lines are driven by the
error counter and report a dead GPU as `OK`; read its per-sample `Gflop/s` column instead, where the
failed device reads `0` with its temperature stuck at idle.

**Admin:** Isolate the node:

```sh
NODE_NAME="<TARGET_NODE>"

kubectl label node "${NODE_NAME}" j3soon/runai-node-pool=dev --overwrite

kubectl get node "${NODE_NAME}" -L j3soon/runai-node-pool
kubectl get node "${NODE_NAME}" \
  -o jsonpath='{.status.capacity.nvidia\.com/gpu}{" capacity, "}{.status.allocatable.nvidia\.com/gpu}{" allocatable\n"}'
kubectl get pods --all-namespaces \
  --field-selector "spec.nodeName=${NODE_NAME}" \
  -o wide
kubectl describe node "${NODE_NAME}" |
  sed -n '/^Allocated resources:/,/^Events:/p'
```

Before submitting the diagnostic, require the node to be `Ready`, labeled for `dev`, and reporting all eight GPUs as both capacity and allocatable. Capacity and allocatable confirm that Kubernetes advertises the devices; they do not show how many GPUs existing pods currently request. For this full-node diagnostic, also require the node's allocated resources to show zero requested GPUs and verify that no bound pod retains them. If Run:ai reports `MaxNodePoolResources` or no GPU resources in `dev`, re-check the node label, Ready state, advertised capacity, current allocations, `dev` pool availability, and project quota; suspending, resuming, or recreating the workload will not repair a node-side fault or free occupied GPUs.

After the node has been isolated in the `dev` node pool, use the [Run:ai REST API node-affinity field](https://run-ai-docs.nvidia.com/api/api-guides/using-node-affinity-via-api) to launch a preemptible 8-GPU diagnostic workspace on its exact hostname. The CLI does not expose general required node affinity: `--node-type` requires a separate `run.ai/type` label, while `--required-pod-topology-key` groups workload pods and does not select a hostname. The REST API can directly match the built-in `kubernetes.io/hostname` label.

Do not pass `--required-pod-topology-key kubernetes.io/hostname=<NODE_NAME>`. CLI 2.23 can serialize the entire `key=value` string as a topology-key name, causing pod creation to fail Kubernetes validation.

This requires `curl`, `jq`, and an authenticated Run:ai CLI session:

```sh
export SSL_CERT_FILE="$HOME/.runai/certs/root-ca.crt"
NODE_NAME="<TARGET_NODE>"
WORKSPACE_NAME=nvlink-diagnostic
RUNAI_AUTHORIZED_USER="<RUNAI_USER_EMAIL>"
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
  --arg authorizedUser "${RUNAI_AUTHORIZED_USER}" \
  --arg args 'jupyter lab --allow-root --ip=0.0.0.0 --no-browser --notebook-dir=/ --NotebookApp.base_url=/${RUNAI_PROJECT}/${RUNAI_JOB_NAME} --NotebookApp.token=' \
  '{
    name: $name,
    projectId: $projectId,
    clusterId: $clusterId,
    spec: {
      args: $args,
      compute: {gpuDevicesRequest: 8, largeShmRequest: true},
      exposedUrls: [{container: 8888, authorizedUsers: [$authorizedUser]}],
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
RUNAI_AUTHORIZED_USER="<RUNAI_USER_EMAIL>"
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
  --external-url "container=8888,authusers=${RUNAI_AUTHORIZED_USER}" \
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
NFS_PROBE_ID="${NODE_NAME}-${WORKSPACE_NAME}-$(date +%s)-$$"
NFS_PROBE="${NFS_MOUNT_PATH}/.runai-nfs-check-${NFS_PROBE_ID}"
NFS_MARKER="nfs-ok-${NFS_PROBE_ID}"
runai workspace exec "${WORKSPACE_NAME}" \
  --project "${RUNAI_PROJECT}" \
  -- bash -c "printf '%s\\n' '${NFS_MARKER}' > '${NFS_PROBE}'"
runai workspace exec "${WORKSPACE_NAME}" \
  --project "${RUNAI_PROJECT}" \
  -- grep -Fqx -- "${NFS_MARKER}" "${NFS_PROBE}"
runai workspace exec "${WORKSPACE_NAME}" \
  --project "${RUNAI_PROJECT}" \
  -- rm -f "${NFS_PROBE}"
```

Write the probe from a shell inside the container rather than piping into
`runai ... exec --stdin`. The `--stdin` form fails with
`Error: failed to exec output. inappropriate ioctl for device`, so the probe never
reaches the mount.

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

## NFS mount fails with `Connection refused` on every node

A workload stays in `Initializing` and its events show a `FailedMount` from the kubelet:

```
MountVolume.SetUp failed for volume "nfs-volume-0" : mount failed: exit status 32
Mounting arguments: -t nfs <server>:<export> ...
Output: mount.nfs: Connection refused
```

Read the error word for word. `Connection refused` means something answered and nothing is
listening; a firewall that drops, or a dead route, gives a **timeout** instead. It is also not an
export-path or permissions fault — a wrong export yields `access denied by server`.

The pod keeps retrying, so the workload sits in `Initializing` indefinitely rather than failing.
Capture the event, then delete it; leaving it queued only holds a scheduling slot.

### Do not diagnose this from a workstation port scan

The obvious next step is to probe the server's RPC ports over the VPN, and it will mislead you.
Observed 2026-09-11 against two different servers on this cluster: a bash `/dev/tcp` connect to
port `111` succeeded while `2049` and `20048` were refused, which reads exactly like "the host is
healthy and only `nfsd` is dead". It is not safe to conclude that. An actual portmap `DUMP` call to
the same open port `111` then **timed out on both servers** — so whatever accepted the TCP
handshake was not rpcbind answering, and something in the path completes handshakes without
forwarding. A TCP connect that succeeds is not evidence that the service behind it is alive.

Probe with a call that requires a reply, not a connect:

```sh
rpcinfo -p <server>           # must list program 100003 (nfs) to mean anything
showmount -e <server>         # exports, if mountd answers
```

Neither ships on a minimal workstation; install `rpcbind`/`nfs-common` rather than substituting a
port scan.

### Let the cluster node be the authority

The kubelet's own `FailedMount` event is the measurement that counts, because it comes from the
host that must actually mount. Test with a throwaway CPU-only workload carrying just the `--nfs`
flag, and read the event rather than the pod logs — the pod never starts, so
`runai ... logs` returns `workload is not ready to stream: pod is not ready`.

When two unrelated servers fail identically from the same node, it is tempting to infer a common
cause — a shared filer front-end, both addresses being virtual IPs on one appliance, or a
network-policy change — and escalate. Before doing that, **try a different server address.**

Observed 2026-09-11: six consecutive `Connection refused` mounts across two servers and two path
depths looked conclusively like an outage, and the diagnosis was wrong. A third address on the same
subnet mounted immediately and reported a healthy 27T filesystem. Nothing was broken; the addresses
being tried were simply not the serving one — including the one registered as the project's own
Run:ai NFS data-source asset.

The lesson is about which variable to hold fixed. `Connection refused` is the kernel saying a host
rejected the connection, which is a statement about *that address*, not about NFS in general. Once
one server has refused every path you try, stop permuting the export path and change the server.
And treat a registered Run:ai data source as a hint like any other: it can name a server that no
longer serves, so it is not automatically more authoritative than an address a user hands you.

Until it is restored, workloads that only read from the network and write container-local paths
still run; anything mounting `/mnt/nfs` cannot start. Drop the `--nfs` flag to keep validating the
parts that do not need it.
