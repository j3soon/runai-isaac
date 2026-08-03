---
name: admin-debug-runai-node
description: Perform explicitly authorized NVIDIA Run:ai cluster-administrator node diagnostics, including isolating or restoring a GPU node with the dev node pool, validating Kubernetes GPU capacity, launching an exact-hostname HPC or NVLink diagnostic workspace through the Run:ai REST API, and interpreting node or pool scheduling failures. Use only for admin debugging of a named node; do not use for normal repository-application or custom user-workload launches.
---

# Admin Debug Run:ai Node

Diagnose one explicitly named GPU node without weakening placement or isolation constraints. Keep normal user workloads in the `launch-runai-workload` skill.

Before taking admin or workload actions, read [references/admin-diagnostics.md](references/admin-diagnostics.md) and the root `troubleshooting.md` section **NVLink Error in a Single Node**.

## 1. Establish authorization and scope

- Require an explicit administrator debugging request. Do not infer authorization to relabel, cordon, drain, reboot, or restore a node from an ordinary workload request.
- Resolve the cluster, project, exact node name, incident symptom, current node pool, intended diagnostic, expected GPU count, storage mapping, and cleanup/restoration owner.
- Record `git status --short`; never change the Git index unless requested.
- Check `kubectl` access and the exact permission needed before mutation. If the environment lacks its admin kubeconfig or node-patch permission, stop and give the authorized operator the exact command.
- Resolve the Run:ai API URL, project ID, cluster UUID, and identity from the active CLI context. Keep API tokens in memory and out of output and files.

## 2. Inspect before isolation

- Read the node's current `j3soon/runai-node-pool` label and record it for possible restoration.
- Check Ready state, taints, `nvidia.com/gpu` capacity and allocatable count, and relevant GPU Operator or device-plugin conditions.
- Correlate the reported failure with workload `Bound`, admission, device-plugin, and scheduler events. Never diagnose the node solely from a failed application log.
- If the node is not Ready or does not advertise the expected GPUs, report that state before trying to launch a full-node diagnostic.

## 3. Isolate the exact node

- With explicit authorization, label only the resolved node into `dev` using the repository's documented node-pool label.
- Verify the label change, Ready state, capacity, and allocatable GPUs after the node-pool controller reconciles.
- Require all eight allocatable GPUs for the documented full-node HPC/NVLink workspace. Do not reduce the request merely to make a broken node schedulable.
- Do not use `prod` for an isolated-node diagnostic.

## 4. Build the diagnostic contract

- Use the published HPC Samples image and Jupyter command from root `troubleshooting.md`; do not pull or test this repository-provided diagnostic image locally unless explicitly requested.
- Resolve NFS from the current Run:ai data-source API. Treat `secrets/env.sh` as a cross-check only and reject placeholders or stale server values.
- Mount the approved export read-write at `/mnt/nfs`; state what persists and what remains ephemeral.
- Restrict the Jupyter URL to the authorized Run:ai user. Do not expose an unauthenticated admin shell.
- Use eight GPUs, large shared memory, `dev`, preemptible/`interactive-preemptible`, and image pull policy `Always` unless the documented diagnostic contract changes.

## 5. Submit with exact hostname affinity

- Show the fully resolved request before submission.
- Do not use `--required-pod-topology-key` for hostname placement. It configures pod topology, and CLI 2.23 may serialize `key=value` as an invalid Kubernetes topology-key name.
- Submit through `POST /api/v1/workloads/workspaces` with `spec.nodeAffinityRequired` matching `kubernetes.io/hostname In [<node>]`.
- Preserve the image entrypoint unless the documented image explicitly requires a command override.
- Never drop the hostname affinity, change to `prod`, enable privilege, or add host access as a scheduling workaround.

## 6. Monitor and verify

- Inspect events while Creating or Pending. Confirm the `Bound` event names the exact target node and reports node pool `dev` before running diagnostics.
- Treat `MaxNodePoolResources` or “No node in the dev node-pool has GPU resources” as a node/pool capacity gate. Re-check label, Ready state, capacity, and allocatable GPUs before recycling the workload.
- Treat `Invalid value ... topologyKey` as evidence that the CLI pod-topology flag was misused; replace the failed workload with the REST affinity request.
- Verify eight visible GPUs, the exact node hostname, the NFS mount and bounded read/write probe, Jupyter's listening message, and the identity-restricted URL.
- Remove only the exact temporary NFS probe created during verification. Keep the real diagnostic workspace until the administrator finishes debugging or explicitly asks for cleanup.

## 7. Restore safely

- Delete or suspend the diagnostic workspace before returning the node to a user pool.
- Restore the recorded original pool only after the administrator confirms the node is repaired and authorizes restoration.
- Re-check Ready state and GPU capacity after restoration. Never return a known-broken node to `prod` automatically.
- Report the node label changes, diagnostic workload state, placement, GPU and NFS evidence, remaining node fault, retained resources, and restoration status.
