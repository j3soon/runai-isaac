# Run:ai Administrator Node Diagnostics

Use this reference only for explicitly authorized administration of one named node. Root `troubleshooting.md` contains the repository's full REST submission example and remains the command source of truth.

## Node gate

Capture the original pool label before mutation:

```bash
kubectl get node <node> -L j3soon/runai-node-pool
```

Isolate the exact node only after authorization:

```bash
kubectl label node <node> j3soon/runai-node-pool=dev --overwrite
kubectl get node <node> -L j3soon/runai-node-pool
kubectl get node <node> \
  -o jsonpath='{.status.capacity.nvidia\.com/gpu}{" capacity, "}{.status.allocatable.nvidia\.com/gpu}{" allocatable\n"}'
kubectl get pods --all-namespaces \
  --field-selector 'spec.nodeName=<node>' \
  -o wide
kubectl describe node <node> |
  sed -n '/^Allocated resources:/,/^Events:/p'
```

Require `Ready`, pool `dev`, the diagnostic's full expected advertised GPU count, and enough currently unallocated GPUs before submission. Allocatable is the scheduling ceiling rather than a live free-device count; inspect bound pods and the node's allocated resources separately. Also verify `dev` pool availability and project quota. Do not evict or delete an occupying workload without explicit authorization.

## Exact placement

The Run:ai CLI's pod-topology flags do not provide general node affinity. Exact hostname placement requires the workspace REST field:

```json
{
  "nodeAffinityRequired": {
    "nodeSelectorTerms": [{
      "matchExpressions": [{
        "key": "kubernetes.io/hostname",
        "operator": "In",
        "values": ["<node>"]
      }]
    }]
  }
}
```

Use the root troubleshooting guide's complete payload. Keep `nodePools: ["dev"]`, eight GPUs, `largeShmRequest: true`, `imagePullPolicy: "Always"`, `interactive-preemptible`, approved NFS, and an explicit authorized Jupyter user.

## Failure routing

| Evidence | Meaning | Action |
|---|---|---|
| `FailedCreate` with invalid `topologyKey` | CLI pod-topology flag was used as hostname affinity | Delete only the failed diagnostic object and resubmit through REST node affinity. |
| `MaxNodePoolResources` or no GPU resources in `dev` | Target is not reconciled into `dev`, is not Ready, lacks advertised capacity, has GPUs requested by existing pods, or is blocked by pool/project availability | Check the node label, Ready state, advertised capacity, current pod GPU requests, `dev` pool availability, and project quota. Do not relax placement or GPU count. |
| Pod binds to another node | Required hostname affinity is absent or wrong | Stop before diagnostics and correct the REST payload. |
| NFS mount failure | Data-source server/export or node-side mount path is wrong or unavailable | Re-resolve the Run:ai data source; do not trust stale `secrets/env.sh` values. |
| Jupyter URL exists but is not reachable | Container is not listening, base URL is wrong, or ingress authorization is incomplete | Inspect workspace logs and the resolved authorized-users setting. |

## Verification

Require all of the following:

1. `describe` shows Running and a `Bound` event for the exact node in `dev`.
2. `nvidia-smi -L` in the workspace reports the expected GPUs.
3. `findmnt -T /mnt/nfs` resolves the approved NFS export.
4. A uniquely named probe can be written, read back with its expected content, and removed from the approved NFS path.
5. Jupyter logs show the expected base URL and listening port.
6. The external URL is restricted to the authorized Run:ai identity.

After debugging, remove or suspend the workspace. Restore the recorded original node-pool label only with explicit authorization and only after the node is healthy.

## Reading the result

**`intranode-comm-test.sh` cannot detect a GPU that dies under sustained load, and neither can
nccl-tests.** Measured on a node that had reported `GPU is lost`: nvbandwidth's 86 test groups,
nccl-tests (`Out of bounds values : 0 OK`), aggregate ECC counters, remapped-row state, and PCIe
link width were all completely clean, and `nvidia-smi` enumerated all eight GPUs throughout. A
300-second `gpu-burn` on the same node then dropped one GPU out of NVML entirely. Do not clear a
node on comms and bandwidth results alone; the burn is the test that discriminates.

A clean run is also dated evidence rather than an all-clear, since these counters reset on reboot.
Report whether the node was restarted between the incident and the run.

### Detecting a dropped GPU

The failure signature, in order of reliability:

1. `nvidia-smi --query-gpu=index --format=csv,noheader | wc -l` returns fewer than expected, while
   `ls /proc/driver/nvidia/gpus/ | wc -l` still returns the full count. The kernel keeps the PCI
   device node after NVML has lost the device; that split is what makes the device plugin emit
   `GPU is lost` during `GetPreferredAllocation`.
2. `gpu-burn`'s per-sample output shows one slot at `0 Gflop/s` with its temperature frozen at idle
   while the others climb.

**Ignore `gpu-burn`'s final `GPU n: OK` summary.** It keys off the error counter, and a worker whose
GPU stopped responding does no work and therefore accumulates no errors, so a dead GPU is reported
`OK`. Read the per-sample Gflop/s column instead.

Capture the baseline `nvidia-smi --query-gpu=index,uuid,serial,pci.bus_id --format=csv` map
**before** loading the node, and identify the failed device by UUID, PCI address, or serial. When a
GPU drops out the survivors renumber, so the index is ambiguous across the failure — the post-failure
index *n* is a different physical card from the pre-failure index *n*. The device plugin's
`devices (x, y)` pair names what it was probing when the call failed, not the broken card, so it
does not identify the culprit either.

Interpret the `GetPreferredAllocation` / `GPU is lost` admission failure as a bus-drop rather than
an NVLink fault when the node's GPUs have no NVLink to begin with — `nvidia-smi topo -m` showing
only `PIX`/`SYS` and `topo -p2p n` returning `NS` for every pair. Root `troubleshooting.md` carries
the full explanation.

## Knowing when the diagnostic is actually done

`intranode-comm-test.sh` runs for well over 15 minutes on an 8-GPU node, and `runai ... exec`
returns `0` as soon as its client disconnects while the in-container process keeps running. Do not
read the exit status, a tail of the log, or a plausible-looking `SUM`/`AVG` block as completion —
nvbandwidth emits many such blocks mid-run. Poll process state instead:

```bash
until runai workspace exec "${WORKSPACE_NAME}" --project "${RUNAI_PROJECT}" \
  -- bash -c "pgrep -f intranode-comm- >/dev/null && exit 1 || exit 0"; do sleep 60; done
```

Starting a second GPU benchmark before the first finishes silently invalidates both. Bandwidth
figures collected under concurrent load look like node degradation and are not; correctness
counters such as nccl-tests' `#wrong` stay valid. Check for a running benchmark before launching
another.

When killing a stray benchmark, a process left in `Z` (zombie) state has already exited and is
merely unreaped because its parent `exec` shell is gone. That is not a stuck GPU operation and
needs no further action.

## Confirming the fault from the node

NVML-side evidence identifies the device; the host kernel log proves the fault and its layer. Pull it
over SSH from the node (the host's `nvidia-smi` is often absent when the driver is GPU-Operator
managed, so work from `dmesg`/`journalctl` and `lspci`):

```bash
sudo dmesg -T | grep -iE "xid|fallen off the bus|link down|card not present|aer_layer"
```

A hardware bus drop looks like this, and names the UUID and board serial directly:

```
NVRM: GPU at PCI:0000:1c:00: GPU-<uuid>
NVRM: GPU Board Serial Number: <serial>
NVRM: Xid (PCI:0000:1c:00): 79, pid=..., name=gpu_burn, GPU has fallen off the bus.
pcieport 0000:18:03.0: pciehp: Slot(3): Link Down
pcieport 0000:18:03.0: pciehp: Slot(3): Card not present
pcieport 0000:18:03.0: AER: aer_layer=Physical Layer, aer_agent=Receiver ID
```

`Xid 79` plus a Physical Layer AER is conclusive hardware evidence: reseat the card and riser first,
then RMA against the board serial. Read the upstream bridge (`0000:18:03.0` above) as blast radius —
other GPUs behind the same PCIe switch are the likeliest next failures if the root cause is the
riser, backplane, or power delivery rather than the card.

**`Xid 154` (`GPU recovery action changed ... to 0x2 (Node Reboot Required)`) fires on every GPU on
the node, not just the failed one.** Until the node is rebooted, the healthy GPUs are
recovery-pending. The device plugin does drop `nvidia.com/gpu` allocatable (8 capacity / 7
allocatable was observed), so the scheduler will not hand out the dead device — but the node still
holds a phantom entry in `/proc/driver/nvidia/gpus` that NVML cannot see, which is the exact state
that produces the original `GetPreferredAllocation` / `GPU is lost` admission failure. Reboot before
returning a partially-failed node to service, then re-run the burn to establish whether the reduced
GPU count is stable.

## Not every reported node is a GPU fault

Two nodes reported in the same incident had unrelated root causes. Check the node's own kernel log
before assuming the GPUs are implicated — one had no Xid events at all across its entire previous
boot, and had instead wedged on a NIC firmware fault:

```
mlx5_core 0000:65:00.0: Firmware over 120000 MS in pre-initializing state, aborting
mlx5_core 0000:65:00.0: mlx5_health_try_recover: health recovery failed
```

Kernel logging then stopped entirely while the boot record ran on for three more weeks, i.e. the node
was hung and nothing alerted on its silence. A reboot clears that state but fixes nothing: the same
firmware is reloaded and the cause is unestablished. Say so plainly rather than reporting the node as
repaired.

Prefer nodes with persistent journald for this work. A node with volatile journald retains only the
current session, so the window covering the original incident is already gone and the fault history
cannot be established — check `journalctl --list-boots` before concluding anything about recurrence.

## Operating on the node itself

When the workstation has no `kubectl` and no admin kubeconfig, a node can still read and patch its
**own** Node object using the kubelet's credentials:

```bash
sudo kubectl --kubeconfig=/etc/kubernetes/kubelet.conf get node "$(hostname -f)" -L <pool-label-key>
sudo kubectl --kubeconfig=/etc/kubernetes/kubelet.conf label node "$(hostname -f)" <pool-label-key>=<pool> --overwrite
```

This works because the repository's node-pool label sits outside the `kubernetes.io`/`k8s.io`
namespaces that the NodeRestriction admission plugin reserves. The identity is `system:node:<name>`
and is refused `list nodes` cluster-wide, so it can only ever affect itself — you cannot relabel a
second node from the first. Treat it as a fallback and tell the user a node relabelled itself, since
the expected route is an admin kubeconfig; give them the equivalent `kubectl label node` command for
their own records.

## Rebooting a node you can only reach over SSH

`Xid 154` legitimately requires a reboot, but **SSH is an in-band path: it disappears the moment the
node goes down.** Before issuing the reboot, confirm whether out-of-band access (BMC/iDRAC console,
remote power control) is actually available, and if it is not, say so to the user and get their
decision before proceeding rather than after. A node that does not complete boot is then
unrecoverable remotely, and no amount of waiting substitutes for a console.

Budget real time before treating a slow return as a failure: an 8-GPU node doing memory training plus
PCIe link-training retries on a degraded slot can take far longer than a normal host. Distinguish the
states from the network:

| Observation | Meaning |
|---|---|
| No ICMP | Host down or still in early POST |
| ICMP replies, **every** TCP port refused | IP stack up, services not started — booting or stalled |
| ICMP replies, SSH open | Up; check `uptime` to confirm the reboot actually happened |

Verify against a healthy sibling node on the same fabric so you are not misreading a network problem
as a host problem, and check whether the cluster marks the pool `Unschedulable` to confirm the node
is genuinely absent rather than merely unreachable from your workstation.

A node that will not boot after a GPU fell off the bus is itself a finding: it suggests the fault
escalated from one unusable GPU to blocked PCIe enumeration, which makes removing or reseating that
card urgent rather than optional. Report it that way.

## Probing the mount

Write the NFS probe from a shell inside the container:

```bash
runai workspace exec "${WORKSPACE_NAME}" --project "${RUNAI_PROJECT}" \
  -- bash -c "printf '%s\n' '${NFS_MARKER}' > '${NFS_PROBE}'"
```

Piping into `runai ... exec --stdin` fails with `inappropriate ioctl for device` and never writes
the file; see `skills/launch-runai-workload/references/runai-cli.md`.

## Contents of the HPC Samples image

`j3soon/hpc-samples:nvhpc-25.7-devel-cuda12.9-ubuntu24.04` ships `/workspace/cuda-samples`,
`nccl-tests`, `nvbandwidth`, and `nvbandwidth_mpi`. It does **not** ship `/workspace/gpu-burn`, so
`hpc-samples/src/scripts/intranode-compute-test.sh` fails on this tag — check what the image
actually contains before promising a gpu-burn run. For a sustained-load check on this tag, use the
image's own `nccl-tests` binaries (for example `all_reduce_perf -b 8 -e 8G -f 2 -g 8 -c 1`), which
also validate correctness, or build gpu-burn into the workspace first.

Upstream gpu-burn's Makefile probes `/usr/bin/nvcc` and `/usr/local/cuda`, neither of which exists in
an NVHPC-SDK image, so a plain `make` dies on a missing `driver_types.h`. Point it at the SDK's own
CUDA and math_libs trees instead (resolve the version directory from the image rather than hardcoding
it):

```bash
CP=/opt/nvidia/hpc_sdk/Linux_x86_64/<ver>/cuda/<cudaver>
MP=/opt/nvidia/hpc_sdk/Linux_x86_64/<ver>/math_libs/<cudaver>
make CUDAPATH=$CP \
  CFLAGS="-O3 -std=c++11 -DIS_JETSON=false -I$CP/targets/x86_64-linux/include -I$MP/targets/x86_64-linux/include" \
  LDFLAGS="-lcuda -L$CP/targets/x86_64-linux/lib -L$CP/targets/x86_64-linux/lib/stubs -L$MP/targets/x86_64-linux/lib -lcublas -lcudart"
```

It builds `compare.fatbin` for `compute_75` by default and JITs to the node's architecture at load,
which is fine for fault detection but means the absolute Gflop/s is not an architecture-native
benchmark — compare against a known-good node, not a published figure.

Build it onto the shared NFS mount and every node in the cluster can reuse the same binary. That
sharing cuts both ways: **each node sees every other node's directories on that mount**, so a probe
like `ls -d <dir>` cannot tell you which node you are on. Give each node its own output directory and
address it explicitly.

The image is ~10.4 GB and `imagePullPolicy: Always` means a cold node pulls it before the container
starts; a 12-minute `Initializing` phase is normal, not a hang.
