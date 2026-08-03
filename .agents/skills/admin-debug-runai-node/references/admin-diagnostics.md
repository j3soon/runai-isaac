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
```

Require `Ready`, pool `dev`, and the diagnostic's full expected GPU count before submission. Kubernetes allocatable capacity is a launch gate, not something a workload retry can repair.

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
| `MaxNodePoolResources` or no GPU resources in `dev` | Target is not reconciled into `dev`, is not Ready, or lacks advertised GPU capacity | Check the node label, Ready state, GPU capacity, and allocatable count. Do not relax placement or GPU count. |
| Pod binds to another node | Required hostname affinity is absent or wrong | Stop before diagnostics and correct the REST payload. |
| NFS mount failure | Data-source server/export or node-side mount path is wrong or unavailable | Re-resolve the Run:ai data source; do not trust stale `secrets/env.sh` values. |
| Jupyter URL exists but is not reachable | Container is not listening, base URL is wrong, or ingress authorization is incomplete | Inspect workspace logs and the resolved authorized-users setting. |

## Verification

Require all of the following:

1. `describe` shows Running and a `Bound` event for the exact node in `dev`.
2. `nvidia-smi -L` in the workspace reports the expected GPUs.
3. `findmnt -T /mnt/nfs` resolves the approved NFS export.
4. A uniquely named probe can be created, checked, and removed from the approved NFS path.
5. Jupyter logs show the expected base URL and listening port.
6. The external URL is restricted to the authorized Run:ai identity.

After debugging, remove or suspend the workspace. Restore the recorded original node-pool label only with explicit authorization and only after the node is healthy.
