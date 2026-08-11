# Run:ai CLI Operations

These patterns target the repository's tested CLI 2.23 family. Run `runai version` and the relevant `--help` before use; prefer the installed CLI's syntax when it differs.

Every Run:ai CLI submit command must include `--image-pull-policy Always`, including commands that use an immutable image digest. Verify this flag in the exact resolved command before executing it.

Do not nest double quotes inside a `--command` argument. They are flattened before reaching the container, so `--command -- /run.sh "python -c \"import x\""` arrives as broken shell and the pod fails on a syntax error while still reporting a generic backoff-limit message. Use single quotes for the inner string, or keep the inner command quote-free. Check the resolved command in the `runai-submit-command` annotation of `runai ... describe` when a job fails immediately.

Every GPU submit command must also include an explicit node pool; do not trust the CLI default. On this repository's configured cluster, pass `--node-pools prod` for user workloads. Node administration and the `dev` pool belong to the `admin-debug-runai-node` skill.

## Readiness

```bash
runai version
runai config describe --json
runai whoami
runai project list --no-pagination
runai workload list --project <project> --json
```

`--no-pagination` returns a **single page**, not the full list; it is the flag that causes the trailing `next token`. Omit it to page through everything, and prefer `--json` when a complete inventory matters. A project can hold far more workloads than the first page shows.

Deleting requires `-y` in a non-interactive shell, or the command aborts with `could not open a new TTY: open /dev/tty`. `runai workload delete -y -p <project> <name>...` accepts several names, but pass them as separate arguments; a single argument holding space-separated names fails with `no workload was found`. `runai workspace delete` has no `-y`, so use `runai workload delete` for both types. Deletion is irreversible and removes the pod logs, so confirm the resolved name list against `runai workload list` first.

## Copying files off the cluster

When FTP is unconfigured and the workstation has no NFS client or passwordless `sudo`, retrieve outputs through a short-lived workspace:

```bash
runai workspace submit <name> --project <project> --node-pools <pool> \
  --image <image> --image-pull-policy Always \
  --nfs "server=<server>,path=<export>,mountpath=/mnt/nfs,readwrite" \
  --command -- /run.sh "python -m http.server 8000 --directory /mnt/nfs/<user>"
runai workspace port-forward <name> --project <project> --port 8000:8000 &
curl -s http://localhost:8000/<path> -o <local-path>
runai workload delete -y -p <project> <name>
```

Verify the copy with `sha256sum` against a checksum taken in-cluster, and delete the workspace when finished.

## Copying files onto the cluster

The repository's documented upload path is FTP (root `README.md`). When the cluster's FTP credentials are unprovisioned — `secrets/env.sh` still holding `<FTP_USER>` / `<FTP_PASS>` — and the workstation has no NFS client or passwordless `sudo`, two obvious substitutes do not work:

- `runai ... exec --stdin` cannot stream binary data. It fails with `Error: failed to exec output. inappropriate ioctl for device` while the `runai` process exits `0`, so a `tar | runai exec -i` pipeline reports success and leaves a 0-byte file.
- `python -m http.server` serves `GET` only, so the download workspace above cannot accept an upload.

What works is a small `PUT`/`GET` endpoint in the staging workspace, reached through the same `port-forward`. Stage the script rather than inlining it, per the command-validation guard above: `base64` it locally, decode it in the pod, and hash-check it before running.

```bash
B64=$(base64 -w0 upload_server.py); SHA=$(sha256sum upload_server.py | cut -d' ' -f1)
runai workspace exec <name> --project <project> -- \
  bash -lc "echo '$B64' | base64 -d > /tmp/upload_server.py; echo '$SHA  /tmp/upload_server.py' | sha256sum --check"
runai workspace exec <name> --project <project> -- \
  bash -lc "nohup <python> /tmp/upload_server.py /mnt/nfs/<username> <token> 8000 > /tmp/upload_server.log 2>&1 &"
runai workspace port-forward <name> --project <project> --port 8000:8000 &
curl -f -T bundle.tgz "http://localhost:8000/<token>/<subdir>/bundle.tgz"
```

Require a random token prefix in the request path: the pod network is shared, so an unauthenticated writer bound to `0.0.0.0` would let any pod write into the NFS user directory. Verify the upload with `sha256sum --check` **in the pod** before extracting, and delete the workspace when finished.

Do not assume `python3` is on `PATH`. Simulator images often ship their interpreter elsewhere (for the Isaac Lab image it is `/isaac-sim/kit/python/bin/python3`); resolve it before starting the endpoint.

The mount is `readwrite`, so one workspace covers both directions: stage inputs, run the real workloads, then pull the outputs back through the same endpoint.

- If the cluster needs a VPN, connect it before diagnosing DNS or TLS.
- For the repository's self-signed cluster, use its locally installed CA through `SSL_CERT_FILE`; never disable TLS verification for credential exchange.
- If authentication expired, use the appropriate `runai login` flow. Never print or persist a password/token in commands, logs, skill files, or Git.
- Pass `--project <project>` to every mutating and verification command even when a default exists.

## NFS mapping

Do not use `--datasource` for now. On CLI `2.25`, a distributed submit copies `--nfs` into both `spec.storage` and `masterSpec.storage`, but copies `--datasource` into `spec.storage` only. The master pod then has no mount, writes to a non-existent path, and still exits `0`, so the output is lost silently. `--master-no-pvcs=false` does not fix it. Always mount with `--nfs`.

Newer releases still list the assets, which is the supported way to resolve the approved mapping:

```bash
runai datasource list --project <project> --type nfs
runai datasource describe <name> --project <project> --type nfs --output json
```

Resolve the asset's actual server and export path at submit time rather than hard-coding them, so an administrator remapping the asset does not silently redirect writes. Then use:

```bash
--nfs "server=<server>,path=<export>,mountpath=/mnt/nfs,readwrite"
```

If only the asset name is known, run:

```bash
<skill-dir>/scripts/discover-nfs.sh --project <project> [--name <asset-name>]
```

The helper retrieves the mapping read-only through the authorized Run:ai data-source API (`GET /api/v1/asset/datasource?projectId=<id>`) and prints only normalized NFS fields. CLI `2.23` requires `runai auth get-token --output plaintext`; its default token output is kubeconfig text and cannot be placed directly in a bearer header. Keep the token in memory and out of terminal output and files. Do not guess a server/export pair from naming alone.

Use `secrets/env.sh` only as a cross-check. Reject values such as `<FTP_USER>` and prefer the current project data-source mapping when `STORAGE_NODE_IP` disagrees with its server.

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

For custom writer and verifier logic, execute reviewed scripts from the image or confirmed NFS path; do not embed them in quoted `python -c` commands. Treat backslash escapes and nested quote-dependent expressions in an inline wrapper as a command-validation error because CLI serialization may change them. Use `echo` for fixed newline-terminated markers and `echo "<sha256>  <path>" | sha256sum --check --status` for staged-file hashes. Inspect the resolved workload command before treating the result as valid.

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

Mount with `--nfs`, never `--datasource`; see the NFS mapping section. Because a missing mount fails silently, assert it before the real command. Inside a `/run.sh "<cmd>" "<cmd>"` chain the guard must be a single bare command, because `/run.sh` runs each argument through unquoted `$1` word splitting and never re-parses `||`, `{`, or `;` as shell operators. `/run.sh` is `#!/bin/bash -ex`, so a nonzero exit aborts the chain:

```bash
/run.sh "mountpoint -q /mnt/nfs" "<real command>"
```

When overriding the entrypoint with an actual shell (`--command -- bash -c '...'`), the explicit form is available:

```bash
mountpoint -q /mnt/nfs || { echo "FATAL: /mnt/nfs is not a mount point"; exit 1; }
```

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

### `exec` is not a synchronous shell

Three separate behaviours, each of which makes a failed remote step look like a successful one:

- **It returns before the in-pod command finishes.** A `wc -l` issued straight after an extract reports `0` while the extract is still writing.
- **It sometimes swallows stdout entirely** while the command still runs to completion. An echoed `BUILD_OK` is therefore not a success signal, and its absence is not a failure signal.
- **It truncates long `&&` chains.** A chain of `rm marker && extract && cp -r && tar && mv && write marker` executed the `rm` and stopped, leaving no marker, no output, and no error.

Run remote work as several short `exec` calls, have the last one write a marker file to the mount, and poll for that marker. Verify by file state, never by `exec`'s return value or output. `runai ... exec --stdin` additionally cannot stream binary — see "Copying files onto the cluster".

### Never read a file that is being written

Downloading an export while the pod regenerated it returned **0 bytes** on three separate cycles, and `tar` of a live log file failed with `file changed as we read it` while leaving the *previous* archive in place, which downloads as a plausible but stale file.

Build to `*.tmp` and `mv` into place (atomic within one filesystem), snapshot directories with `cp -r` to `/tmp` before archiving, and assert the artifact **grew** against the previous copy before trusting it. That growth assertion is what catches a stale pull; every individual command reports success. Note `cp -a` fails on some NFS mounts (`preserving permissions: Operation not supported`) — use `cp -r`.

### Session lifetimes during long runs

Workloads outlive the things you watch them with. Over a multi-day run: `port-forward` dies after roughly 55 minutes (the endpoint stops answering while the process still looks alive), the auth token expires and its SSO re-login is **interactive**, a VPN drop makes `workload list` return empty and DNS fail — check the tunnel before concluding the jobs died — and a staging workspace ends whenever its `sleep` does, so give it `sleep 86400` rather than `sleep 3600`.

Logs survive completion: `runai ... logs` still serves a `Completed` workload's output, which is lost only on `runai workload delete`.

## Cleanup

```bash
runai training standard delete <name> --project <project>
runai training pytorch delete <name> --project <project>
runai workspace delete <name> --project <project>
```

Delete only the workload type and name created for validation. Confirm the exact target with `describe` first. Do not delete durable NFS outputs with the workload.
