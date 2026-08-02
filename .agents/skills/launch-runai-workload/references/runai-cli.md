# Run:ai CLI Operations

These patterns target the repository's tested CLI 2.23 family. Run `runai version` and the relevant `--help` before use; prefer the installed CLI's syntax when it differs.

Every Run:ai CLI submit command must include `--image-pull-policy Always`, including commands that use an immutable image digest. Verify this flag in the exact resolved command before executing it.

Every GPU submit command must also include an explicit node pool; do not trust the CLI default. On this repository's configured cluster, always pass `--node-pools prod`.

## Readiness

```bash
runai version
runai config describe --json
runai whoami
runai project list --no-pagination
runai workload list --project <project> --no-pagination
```

- If the cluster needs a VPN, connect it before diagnosing DNS or TLS.
- For the repository's self-signed cluster, use its locally installed CA through `SSL_CERT_FILE`; never disable TLS verification for credential exchange.
- If authentication expired, use the appropriate `runai login` flow. Never print or persist a password/token in commands, logs, skill files, or Git.
- Pass `--project <project>` to every mutating and verification command even when a default exists.

## NFS mapping

First inspect the installed CLI. Newer releases expose data-source assets directly:

```bash
runai datasource list --project <project> --type nfs --json
runai datasource describe <name> --project <project> --type nfs --output json
```

When the selected submit command supports `--datasource`, attach the approved asset by name using the exact format shown by its `--help` output. This preserves the administrator-managed mapping.

The repository's tested CLI `2.23` does not expose `runai datasource` or a submit-time `--datasource` flag. On that version, a dashboard data-source name cannot be passed as the direct NFS specification. Resolve its actual server and export path, then use:

```bash
--nfs "server=<server>,path=<export>,mountpath=/mnt/nfs,readwrite"
```

If only the asset name is known, run:

```bash
<skill-dir>/scripts/discover-nfs.sh --project <project> [--name <asset-name>]
```

The helper retrieves the mapping read-only through the authorized Run:ai data-source API (`GET /api/v1/asset/datasource?projectId=<id>`) and prints only normalized NFS fields. CLI `2.23` requires `runai auth get-token --output plaintext`; its default token output is kubeconfig text and cannot be placed directly in a bearer header. Keep the token in memory and out of terminal output and files. Do not guess a server/export pair from naming alone.

The repository convention uses one lab-scoped export mounted at `/mnt/nfs`, with user-owned paths below `/mnt/nfs/<username>`. Verify the selected project belongs to the same lab scope.

## Finite single-pod training

Use this shape for a bounded headless run:

```bash
runai training standard submit <name> \
  --project <project> \
  --image <image> \
  --image-pull-policy Always \
  --node-pools prod \
  --gpu-devices-request 1 \
  --large-shm \
  --nfs "server=<server>,path=<export>,mountpath=/mnt/nfs,readwrite" \
  --backoff-limit 0 \
  --restart-policy Never \
  --command -- <executable> <arguments...>
```

Omit GPU or large shared memory only when the application and cluster policy permit it. Omitting `--command` preserves the image entrypoint and treats values after `--` as arguments.

For a multi-line custom program, prefer executing a reviewed script from the image or confirmed NFS path. Avoid layers of shell quoting that cannot be inspected reliably in `describe`. If a small non-secret validation snippet must be transported inline, verify its decoded content/hash and inspect the resolved workload command before treating the result as valid.

## Interactive workspace

Use this shape only for a service the user intends to connect to:

```bash
runai workspace submit <name> \
  --project <project> \
  --image <image> \
  --image-pull-policy Always \
  --node-pools prod \
  --gpu-devices-request 1 \
  --large-shm \
  --nfs "server=<server>,path=<export>,mountpath=/mnt/nfs,readwrite" \
  --backoff-limit 0 \
  --command -- <service-command> <arguments...>
```

Add only the required `--port` or `--external-url` settings. Verify authentication/authorization before exposing Jupyter, VSCode, noVNC, SSH, TensorBoard, or another service. Suspend or delete the workspace when no longer needed.

## Distributed PyTorch

Use a PyTorch workload so the operator supplies rank and rendezvous data:

```bash
runai training pytorch submit <name> \
  --project <project> \
  --image <image> \
  --image-pull-policy Always \
  --node-pools prod \
  --workers 1 \
  --gpu-devices-request 1 \
  --master-gpu-devices-request 1 \
  --large-shm \
  --nfs "server=<server>,path=<export>,mountpath=/mnt/nfs,readwrite" \
  --backoff-limit 0 \
  --restart-policy Never \
  --master-restart-policy Never \
  -- <image-entrypoint-arguments...>
```

One worker plus the master creates two pods. Confirm whether the master participates in training for the selected image. If overriding commands, inspect `--master-command`, `--master-args`, and `--command` help rather than assuming one override applies identically to every pod.

## Persistent-storage probe

Use a unique path and the same NFS mapping as the real workload. A typical in-container probe is:

```bash
set -eu
umask 077
mkdir -p "/mnt/nfs/<username>/.runai-probes"
printf '%s\n' "<unique-marker>" > "/mnt/nfs/<username>/.runai-probes/<name>.txt"
sync
test -s "/mnt/nfs/<username>/.runai-probes/<name>.txt"
```

Let the writer exit, then verify the marker independently. Remove that exact marker after verification.

## Monitor and diagnose

```bash
runai workload list --project <project> --no-pagination
runai workload describe <name> --project <project> --type <training|workspace> --events --pods
runai training standard logs <name> --project <project> --timestamps --tail 200
runai training standard exec <name> --project <project> -- <command...>
```

Use the matching `workspace` or `training pytorch` subcommand for logs/exec/delete. For distributed jobs, take pod names from `describe` and retrieve logs from every pod with `--pod`.

While a workload is pending, inspect events for quota, placement, PVC/NFS, image pull, admission, or policy errors. While it is running, inspect application logs and GPU/process state. After completion, record the exit state before cleanup.

Prefer `runai ... exec` or `runai ... bash` over node SSH. Use SSH only through an explicitly exposed, authorized workspace service; never assume cluster-node SSH access.

## Cleanup

```bash
runai training standard delete <name> --project <project>
runai training pytorch delete <name> --project <project>
runai workspace delete <name> --project <project>
```

Delete only the workload type and name created for validation. Confirm the exact target with `describe` first. Do not delete durable NFS outputs with the workload.
