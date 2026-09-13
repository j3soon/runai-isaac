# Run:ai CLI Operations

These patterns target the repository's tested CLI 2.23 family. Run `runai version` and the relevant `--help` before use; prefer the installed CLI's syntax when it differs.

Every Run:ai CLI submit command must include `--image-pull-policy Always`, including commands that use an immutable image digest. Verify this flag in the exact resolved command before executing it.

**The CLI rewrites the quoting of `--command`, swapping your outer and inner quote characters.**
Submitting `--command -- /run.sh "python -c 'import x; import y'"` stores and runs
`/run.sh 'python -c "import x; import y"'`. The inner string therefore arrives double-quoted no
matter which way round you wrote it, so you cannot fix this by choosing the other quote style.

That matters because `/run.sh` word-splits its argument unless given `--shell`: the inner command
reaches `python` as `-c` `"import` `x;` ... and dies with
`SyntaxError: unterminated string literal`, while the workload reports only a generic backoff
failure. **Pass `--shell` whenever the command contains a quoted string, `&&`, a pipe or a
redirect** — it makes `/run.sh` `eval` the argument, which survives the rewrite:

```bash
--command -- /run.sh --shell "python -c 'import torch; print(torch.__version__)'"
```

Check the rewrite in the `Command:` line of `runai ... describe` *before* waiting on a pull; on a
large image the failure otherwise costs a full image pull to discover. Note `describe` returns no
`Command:` line at all while the workload is still in `Creating`.

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


`global.update.auto: true` lets the CLI silently self-upgrade mid-session (observed 2.23.34 -> 2.25.27 within one session), so the command contract can change between two commands in the same shell. Re-check `--help` after any run that spans an upgrade.
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
- Smuggling the payload in an environment variable fails the submit outright: `Error: failed to submit ... Value: value for Value must have at most 10000 characters`. Splitting one `base64` blob across two env vars does **not** help, so the cap is not per-variable. A 10 KB tarball is already about 13.4 KB of `base64`, so this rules out all but the smallest bundles.
- Inlining the same `base64` in the `exec` command line fails differently, because `exec` is proxied over HTTP and the command travels in a header: `Error: failed to exec output. got error while trying to stream workload: <html>... 400 Request Header Or Cookie Too Large`. Measured: ~3.3 KB of `base64` passes, ~13.4 KB does not.

Those two limits are why the recipe below bootstraps a *small* script by `exec` and moves the real payload over `port-forward`, rather than inlining the payload directly.

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

Extract with `tar --no-same-owner`. The mount is NFS, so a plain `tar xzf` fails per file with `Cannot change ownership to uid <n>, gid <n>: Operation not permitted` and exits `2` — see [developer-notes](../../../docs/developer-notes.md). Because the failure is non-zero, an `&&` chain stops there, which conveniently leaves the uploaded archive in place for a retry.

Do not assume `python3` is on `PATH`. Simulator images often ship their interpreter elsewhere (for the Isaac Lab image it is `/isaac-sim/kit/python/bin/python3`); resolve it before starting the endpoint.

The mount is `readwrite`, so one workspace covers both directions: stage inputs, run the real workloads, then pull the outputs back through the same endpoint.

- If the cluster needs a VPN, connect it before diagnosing DNS or TLS.
- For the repository's self-signed cluster, use its locally installed CA through `SSL_CERT_FILE`; never disable TLS verification for credential exchange.
- If authentication expired, use the appropriate `runai login` flow. Never print or persist a password/token in commands, logs, skill files, or Git.
- Pass `--project <project>` to every mutating and verification command even when a default exists.

## Two workloads can talk directly by pod IP

A server/client split across two images (for example a policy server in one image and an
Isaac Lab simulator in another) cannot share a container, and a standard submit has no
sidecar. A Kubernetes Service is one answer, but it is not required: pods in the same
project namespace reach each other directly on the pod network.

```bash
# In the server pod:
runai workspace exec <server> --project <project> -- bash -c 'hostname -i'
# -> 192.168.32.168

# In the client workload, address the server by that IP:
-e POLICY_URL=http://192.168.32.168:8005
```

Verified with a Cosmos 3 policy server in a workspace and an Isaac Lab eval client in a
separate training workload: the client fetched `/info` and ran a full closed-loop
evaluation against it. Have the client poll the endpoint before starting, since the two
workloads schedule independently:

```bash
until curl -sf -m 5 "$POLICY_URL/info" >/dev/null; do sleep 15; done
```

The IP is not stable across pod restarts, so read it at launch time rather than hard-coding
it, and prefer a Service for anything long-lived.

Co-locating server and client this way also avoids `port-forward` entirely, which matters
for large responses: a forwarded connection truncates them
(`IncompleteRead(856060 bytes read, 566239 more expected)`).

## Idle GPU timeout reaps long-lived workspaces

A project can carry an idle-GPU timeout. On this cluster a workload whose GPU sits idle for
**4 consecutive hours** is stopped. A suspension event reports the project's configured
limit, which may be a different (longer) figure than the idle threshold, so read the event
rather than inferring the policy from it:

```
WorkloadTimeoutApproaching  ... as long as the GPU(s) used by ...
WorkloadTimeoutReached      The workload has reached the idle time limitation
                            on the project (10 hours - 21 minutes)
Suspended                   Job suspended
SuccessfulDelete            Deleted pod: <name>-0-0
```

The workload moves to `Phase: Stopped` and the pod disappears, so `runai ... exec` then
fails with `workload is not ready to stream: pod not found`. Anything on the NFS mount
survives; anything in the pod does not.

This matters for the server/client split: a policy server parked in a long-lived workspace
is exactly the shape that gets reaped, and a server idling between evaluations accrues idle
time. Prefer a **self-contained job** that starts the server, runs the client, and exits, or
a short-lived server workload submitted alongside each evaluation. Reserve workspaces for
interactive debugging, and re-read the pod IP after any restart because it changes.

## Polling for completion: anchor on `^Phase:`

`runai ... describe` prints a pod table whose columns include **`Completed At`**, so a
naive readiness loop matches the header and reports a still-running job as finished:

```bash
# Wrong — "Completed At" is a column header, matches immediately
until runai training standard describe <name> -p <project> | grep -qE "Succeeded|Failed|Completed"; do ...

# Right — the phase line is the only authoritative status
until runai training standard describe <name> -p <project> \
        | grep -E "^Phase:" | grep -qE "Succeeded|Failed|Completed"; do ...
```

`runai ... exec` against a pod that is scheduled but not yet started fails with
`workload is not ready to stream: pod is not ready`, so gate an exec loop on a trivial
`echo READY` round-trip rather than on the workload phase.

## Three shell traps in long-running wrapper scripts

Each fails silently or kills the wrapper itself, and all three cost a job here.

- `set -e` plus `[ -f x ] && cp x y` aborts the whole script when the file is absent, because
  the failed test is the last command of the statement. Write `if [ -f x ]; then cp x y; fi`, or
  append `|| true`. This bites hardest in optional copy-the-overlay steps, which then abort a job
  that had nothing wrong with it.
- `pkill -f <pattern>` matches the command line of the shell running it, so a cleanup line inside
  a script can kill its own `exec` shell and the job exits `143` with no error message. Match a
  PID captured at launch instead.
- `${VAR:-{"a": 1}}` does not survive brace parsing, so a JSON default arrives mangled and
  `json.loads` fails on input that looks correct in the script source. Require the variable
  instead: `: "${VAR:?set VAR}"`.

Order the definitions too: a block appended to a script that references a variable defined further
down fails with `unbound variable` only on the path that reaches it, which may be hours into a run.

Note the submitting shell matters as well. In zsh an unquoted `$names` is **not** word-split, so
`runai workload delete -y -p <project> $names` passes the whole list as a single argument and
fails with `no workload was found`. Loop over the names, or use `${=names}`.

## Workload names are DNS labels

Names accept lowercase alphanumerics and hyphens only. An underscore is rejected at submit
time, so a name derived from a config key (`ns_droid`, `so101_long`) fails validation while
the same string with hyphens succeeds. Translate `_` to `-` when generating names
programmatically from experiment identifiers, and keep the mapping written down — the
workload list is the only place the experiment name survives.

## Always pass `--node-pools`

GPU quota is per node pool, so a project's headline quota says nothing about where a pod can land. Omitting `--node-pools` sends the workload to `default`, which on this cluster holds no GPU nodes. The submit succeeds and the workload then sits in `Pending` indefinitely; only `runai workspace describe` reveals why, in an `Unschedulable` event:

```
No node in the default node-pool has GPU resources.
Non-preemptible workload is over quota. Workload requested 1 GPUs, but <project> quota is 0 GPUs
```

That second line is easy to misread as the whole project being out of quota, while `runai project list` shows a large quota — the two figures are scoped differently. Name the GPU pool explicitly on every submit (`--node-pools prod` for the L40 nodes), and treat a workload still `Pending` after a minute as a scheduling problem to describe rather than a slow start.

Deleting is not instantaneous either: a resubmit under the same name right after `runai workload delete` fails with `Workspace named '<name>' already exists in the project`. Poll `runai workload list` until the name disappears before resubmitting.

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

## Secrets and environment variables

Three ways to set a variable, in increasing order of exposure. The first is the safest but usually needs an administrator to provision the credential; see the note below before planning around it.

```bash
# 1. Credential asset. Requires cluster 2.22+ (2.23+ for ngcApiKey).
#    `create` often returns 403 for a user account -- see the note below.
runai my-credential create hf-token --type genericSecret --item key=HF_TOKEN,value="$HF_TOKEN"
runai my-credential list
runai training standard submit ... \
  --env-my-credentials type=genericSecret,name=HF_TOKEN,credential-name=hf-token,key=HF_TOKEN

# 2. An existing Kubernetes secret in the project namespace.
--env-secret HF_TOKEN=<secret-name>,key=<secret-key>

# 3. A plain value, visible to every project member.
-e HF_TOKEN=<token>
```

In `--env-my-credentials`, `name=` is the environment variable to set, `credential-name=` is the credential asset, and `key=` selects one item inside it (required only for `genericSecret`). One credential can hold several pairs; repeat `--item` when creating it.

Form 3 stores the token in the workload spec, where `runai workload describe` prints it back to anyone with access to the project. Use it only for a non-secret value or a single-user project. Gated Hugging Face repositories (`Cosmos-Reason2-2B`, `Cosmos-Guardrail1`) need a real token in every non-interactive workload, because `hf auth login` is interactive and cannot run there.

Read the token into the environment rather than typing it: `read -rs HF_TOKEN` keeps the literal `$HF_TOKEN` in shell history instead of the value.

Do not plan a workload around creating a credential. `runai my-credential create` needs a permission a user account may not have, and fails with a bare `403 Forbidden` that looks like a malformed `--item` rather than an authorization error; `list` still succeeds, so the API being reachable proves nothing. Use form 1 only against a credential an administrator has already provisioned (`runai credential list` shows them), and otherwise use form 2 or form 3 with its exposure understood.

Related flags: `--image-pull-my-credentials type=dockerRegistry,name=<credential>` authenticates a private image pull, and `--secret-volume path=<path>,name=<secret>` mounts a secret as files when an application wants a file rather than a variable.

The flag contract above is read from CLI 2.25.27 `--help`; injection into a running pod is unverified. On first use, confirm with `runai training standard exec <name> --project <project> -- printenv HF_TOKEN` before concluding a gated download failed for another reason.

## Preemption

`--preemptible` lets a workload schedule above guaranteed quota and be reclaimed at any time. The flag is not uniform across workload types: on CLI 2.25.27 only `runai workspace submit` accepts it. Both `runai training standard submit` and `runai training pytorch submit` accept `--preemptibility <preemptible|non-preemptible>` and reject `--preemptible` as an unknown flag, so the workspace example in the root `README.md` cannot be copied into either training submit unchanged. Confirm with the exact subcommand's `--help`.

It is the only unexpected asymmetry among the three submit shapes: a full flag diff on 2.25.27 shows 97 distinct flags, of which 21 differ across subcommands, and every other difference is the expected `--master-*`/`--workers`/`--no-master` set on `pytorch` and `--parallelism`/`--runs` on `standard`.

Treat preemption as a correctness setting, not only a scheduling one. A reclaimed pod loses in-flight work and can leave a partial artifact that reads as a complete one. Keep scored benchmark repetitions and any run with an unguarded output path non-preemptible; reserve preemptible for interactive or restartable work. `install.md` documents the cluster's priority classes.

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

Expose a service only when the user must reach it from outside the cluster:

```bash
--port "service-type=NodePort,container=8000,external=30080"
--external-url "container=8000,url=https://<host>,authusers=<user>,authgroups=<group>"
```

`--external-url` carries the Run:ai authorization fields; a bare `--port` NodePort does not. Verify authentication before exposing Jupyter, VSCode, noVNC, SSH, TensorBoard, or another service, and restrict anything that grants a shell, a notebook kernel, or write access to `/mnt/nfs` to the authorized user.

Exposure is not the only reachability path: the pod network is shared, so a service bound to `0.0.0.0` without a token is reachable from other pods even with no port or URL exposed. For a service only you need, `runai workspace port-forward <name> --project <project> --port <local>:<container>` requires no exposure at all and is the safer default — but the forward dies after roughly 55 minutes, so re-establish it rather than trusting a stale one (see session lifetimes).

Suspend or delete the workspace when no longer needed.

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

One worker plus the master creates two pods, and `--workers N` creates `N + 1`. The master **does** participate in training as `node_rank` 0: a `--workers 7` submit running eight processes per pod was measured producing `world_size: 64`, so size a job as `nnodes = workers + 1`.

`--command` and `--master-command` are separate flags covering different pods. The validated pattern is to set both to the same thing — `--master-command "<string>"` for the master and `--command -- <argv...>` for the workers. Passing only `--command` was not tested against the master, so set both explicitly rather than relying on either default. The same split applies to `-e` versus `--master-environment-variable`, and to `--gpu-devices-request` versus `--master-gpu-devices-request`.

**Measure the scaling shape before committing a large allocation.** On a validated 1/2/4/8-node
sweep of one GPU-bound workload, crossing from single-node to multi-node cost a **one-time** step
penalty as the intra-node interconnect gave way to the network; each doubling after that scaled
close to linearly. A two-point extrapolation from the single-node baseline therefore reads as
"scaling is poor" when it is only the first hop that is expensive. A third point is cheap next to
a multi-day allocation. Note also that per-iteration wall-clock *grows* with node count even as
throughput rises, so at a fixed step count more nodes buy a larger effective batch, not a shorter
run — size the job for the batch you want.

Mount with `--nfs`, never `--datasource`; see the NFS mapping section. Because a missing mount fails silently, assert it before the real command. In `/run.sh`'s default mode the guard must be a single bare command, because each argument is run through unquoted `$1` word splitting and `||`, `{`, and `;` are never re-parsed as shell operators (`--shell` lifts this — see below). `/run.sh` is `#!/bin/bash -ex`, so a nonzero exit aborts the chain:

```bash
/run.sh "mountpoint -q /mnt/nfs" "<real command>"
```

When overriding the entrypoint with an actual shell (`--command -- bash -c '...'`), the explicit form is available:

```bash
mountpoint -q /mnt/nfs || { echo "FATAL: /mnt/nfs is not a mount point"; exit 1; }
```

### Multi-node rendezvous: `/run.sh` cannot pass it through

The operator injects the Kubeflow rendezvous variables into every pod — `RANK` (pod index),
`WORLD_SIZE` (pod count), `MASTER_ADDR`, and `MASTER_PORT` — and a multi-node launcher has to
read them at runtime.

`/run.sh` in its default mode cannot do that. It executes each argument as unquoted `$1`, which
performs word splitting but **no parameter expansion**, so `$RANK` and `$MASTER_ADDR` reach the
program as literal dollar-sign strings rather than values. A `torchrun` line written into a
plain `/run.sh` argument therefore fails or silently rendezvouses wrong.

On images shipping `/run.sh` v2 or newer, pass `--shell` and write the command normally:

```bash
--command -- /run.sh --shell 'exec torchrun --nnodes=$NNODES --nproc_per_node=<n> \
  --node_rank=$RANK --master_addr=$MASTER_ADDR --master_port=$MASTER_PORT <script> <args...>'
```

`--shell` runs each command through `eval`, so quoting, `$VARIABLES`, pipes, redirects and `&&`
behave as written; v2 also sets `pipefail`, so a failing left-hand pipe stage is no longer masked.

Check what an image ships with `/run.sh --version`; it prints the contract version, and an image
predating the flag exits 1 with `Unknown option --version`, which identifies it as v1. Older
instructions keep working unchanged on both, because `--shell` is opt-in — but a `--shell`
instruction run against a v1 image fails immediately with `Unknown option --shell` rather than
misbehaving, so state a minimum version in guides that use it. A published image only gains a new
contract version when it is rebuilt, so several generations are always in circulation.

Two options work on v1 images. Override the entrypoint with a real shell:

```bash
--command -- bash -c 'exec torchrun --nnodes="$NNODES" --node_rank="$RANK" ... <script>'
```

Or, to keep the submit line free of nested quoting, stage a launcher on shared storage and
invoke it by path from both `--master-command` and `--command`. Staging it also lets both pod
roles share one definition and keeps job shape (`nnodes`, iteration budget) in `-e` variables.
Set the same variables with both `-e` and `--master-environment-variable`; they are separate
flags, as with the command flags above.

Prefix the final command with `exec` in any of these forms. Without it the workload runs as a
child of `/run.sh`, which is PID 1, and a non-interactive bash defers signal handling while
waiting on a foreground child — so the workload never sees the SIGTERM sent on stop and is
SIGKILLed after the grace period, losing any shutdown checkpoint. Do not combine `exec` with
`--upload-src`/`--upload-dest`, since the upload step runs after the commands.

Note `--large-shm` has no `--master-*` counterpart. Verify the master pod actually received the
larger `/dev/shm` rather than assuming the flag propagated.

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

### Console logs are not durable storage

Log retrieval depends on the pod still existing on its node, which is weaker than it sounds:

- **`suspend` destroys them.** Suspending deletes the pods, and every subsequent `logs` call
  returns `one of requested resource was not found: not found`. On an eight-pod job suspended
  mid-run, only the one pod log captured beforehand survived; the other seven were gone.
- **Completed pods get pruned unpredictably.** Two workloads that completed on the *same day*
  behaved differently: one still returned tens of thousands of lines, the other failed with
  `unable to retrieve container logs for containerd://<id>`. This is per-node container
  pruning, not an age threshold, so no retention window can be relied on.

Treat console output as ephemeral. Capture anything worth keeping to shared storage while the
workload is still running, and pull it before suspending or deleting. Application-written files
under the mounted export are unaffected by any of this — only the container's stdout/stderr is
at risk.

Prefer `runai ... exec` or `runai ... bash` over node SSH. Use SSH only through an explicitly exposed, authorized workspace service; never assume cluster-node SSH access.

### `exec` is not a synchronous shell

Three separate behaviours, each of which makes a failed remote step look like a successful one:

- **It returns before the in-pod command finishes.** A `wc -l` issued straight after an extract reports `0` while the extract is still writing.
- **It sometimes swallows stdout entirely** while the command still runs to completion. An echoed `BUILD_OK` is therefore not a success signal, and its absence is not a failure signal.
- **It truncates long `&&` chains.** A chain of `rm marker && extract && cp -r && tar && mv && write marker` executed the `rm` and stopped, leaving no marker, no output, and no error.

Run remote work as several short `exec` calls, have the last one write a marker file to the mount, and poll for that marker. Verify by file state, never by `exec`'s return value or output. `runai ... exec --stdin` additionally cannot stream binary — see "Copying files onto the cluster".

A fourth trap is self-inflicted: **`pkill -f` inside an `exec` matches the `exec`'s own shell**,
because the pattern you are searching for is itself part of that shell's command line. It does
not even need to be the `pkill` argument — a pattern appearing in an unrelated `rm -f
/tmp/<name>.py` later in the same command is enough. The shell SIGTERMs itself, the call
returns `command terminated with exit code 143`, and the remaining steps never run, so the
cleanup looks done and is not. The `[x]` bracket trick is unreliable here for the same reason.
Resolve the PID in one `exec` and kill it by number in the next, then confirm by state:

```bash
runai ... exec <name> --project <project> -- bash -lc 'ps -eo pid,args | grep "[m]yserver"'
runai ... exec <name> --project <project> -- bash -lc 'kill <pid>'
```

Deleting the whole workspace is simpler when the pod is disposable — it takes the processes and
any pod-local files with it.

### Never read a file that is being written

Downloading an export while the pod regenerated it returned **0 bytes** on three separate cycles, and `tar` of a live log file failed with `file changed as we read it` while leaving the *previous* archive in place, which downloads as a plausible but stale file.

Build to `*.tmp` and `mv` into place (atomic within one filesystem), snapshot directories with `cp -r` to `/tmp` before archiving, and assert the artifact **grew** against the previous copy before trusting it. That growth assertion is what catches a stale pull; every individual command reports success. Note `cp -a` fails on some NFS mounts (`preserving permissions: Operation not supported`) — use `cp -r`.

### VPN: reinstall and reconnect without asking

**The VPN profile in `secrets/` is dedicated to agentic use. Reinstalling and reconnecting it
is pre-authorized routine maintenance — do it silently as part of restoring connectivity, and
do not stop to ask permission.** Only escalate to the user when the tunnel still fails after a
full clean cycle, and then report what was already tried.

The full cycle, in order:

```bash
bash scripts/vpn/disconnect.sh        # ignore "No sessions started" — it is not an error
bash scripts/vpn/uninstall_config.sh  # only needed if a stale config is present
bash scripts/vpn/install_config.sh agent.ovpn
bash scripts/vpn/connect.sh
```

A workstation reboot clears the imported OpenVPN profile, not just the connection, so
`connect.sh` alone fails on a missing config rather than reporting a credential problem.
Always re-import before connecting.

**Recognize the symptom.** `runai workload list` failing with
`DNS lookup failed for '<cluster host>': server misbehaving`, or returning an empty list, is a
dead tunnel — not deleted workloads and not a dead job. Cluster workloads keep running while
the tunnel is down; only your visibility is lost. Check the tunnel before concluding anything
about job state.

**Distinguish a stuck tunnel from a down server.** `openvpn3 sessions-list` showing
`Status: Client connecting` with an empty `Device:` field means the handshake never completed;
`disconnect.sh` then reports a climbing `N_RECONNECT` count. Before escalating, rule out the
local causes:

| check | command | local problem if |
| --- | --- | --- |
| general connectivity | `curl -s -o /dev/null -w '%{http_code}' https://github.com` | not 200 |
| endpoint port | `nc -zvu <host> 1194` | refused (note: UDP probes often false-positive) |
| certificate validity | extract `<ca>`/`<cert>` from the `.ovpn`, `openssl x509 -noout -dates` | expired |
| profile imported | `openvpn3 configs-list \| grep <name>` | absent |

All four passing while the session stays in `Client connecting` points at the VPN server, not
the workstation. Note that multiple profiles may share one endpoint (`grep '^remote' *.ovpn`),
in which case switching profiles is not a fallback.

Auth is separate from the tunnel: `Error: Authentication failed. the token has expired` needs
`runai login`, which is an **interactive SSO flow the agent cannot drive** — that one does
require asking the user.

### Session lifetimes during long runs

Workloads outlive the things you watch them with. Over a multi-day run: `port-forward` dies after roughly 55 minutes (the endpoint stops answering while the process still looks alive), the auth token expires and its SSO re-login is **interactive**, a VPN drop makes `workload list` return empty and DNS fail — check the tunnel before concluding the jobs died — and a staging workspace ends whenever its `sleep` does, so give it `sleep 86400` rather than `sleep 3600`.

Logs often survive completion — `runai ... logs` will usually still serve a `Completed` workload's output — but this is not guaranteed and must not be treated as storage. See "Console logs are not durable storage" above.

## Cleanup

```bash
runai training standard delete <name> --project <project>
runai training pytorch delete <name> --project <project>
runai workspace delete <name> --project <project>
```

Delete only the workload type and name created for validation. Confirm the exact target with `describe` first. Do not delete durable NFS outputs with the workload.

For an idle interactive workspace the user still wants, suspend instead of deleting. Suspending releases the GPUs while keeping the workload and its definition; deleting is irreversible and also destroys the pod logs:

```bash
runai workspace suspend <name> --project <project>
runai workspace resume <name> --project <project>
runai training standard suspend <name> --project <project>
```

## Pass `--large-shm` to any workload with PyTorch DataLoader workers

A multi-GPU training job that loads, builds the model, initializes the optimizer and then dies on an
arbitrary rank with nothing but

```
scripts/train.py FAILED
Root Cause (first observed failure):
  rank : 3 (local_rank: 3)
  exitcode : 1
  traceback : <N/A>
```

is very often out of **shared memory**, not GPU memory. The DataLoader passes decoded tensors between
worker processes through `/dev/shm`, which Kubernetes defaults to 64MB, and a video pipeline exhausts
that immediately. The real exception is
`RuntimeError: DataLoader worker (pid N) is killed by signal: Bus error. It is possible that
dataloader's workers are out of shared memory.`

`runai ... submit --large-shm` fixes it. `num_workers=0` also avoids it, at a throughput cost.

Observed 2026-09-11: four consecutive FastWAM training attempts were misdiagnosed as CUDA OOM and
"fixed" by shrinking the batch, which changed nothing, because the fault was never on the GPU.

## Get the real traceback: `torch.distributed` hides non-rank-0 stderr

`ChildFailedError` prints a summary naming the failing rank and its exit code, and **not** that rank's
Python exception. Rank 0's traceback appears in the pod log; every other rank's does not. Two habits
make this tractable:

- **Tee the job's output to the NFS mount.** Run:ai replaces a failed pod, and `runai ... logs` then
  shows the *replacement* — the failing pod's log is gone, and `--previous` returns
  `previous terminated container ... not found`. A log on NFS survives.
  `/run.sh --shell "<command> 2>&1 | tee /mnt/nfs/<user>/<job>.log"`.
- **Read that log with `grep -a`.** Progress bars leave control characters, so the file is detected as
  binary and plain `grep` prints only `binary file matches`, which reads like an empty result.
  `tr -c '[:print:]\n' ' ' < log` is a good first filter before grepping.

Reproducing at `nproc_per_node=1` also surfaces the exception directly, but beware that a single-GPU
run can fail *earlier and differently* — a ZeRO partition that fits across 8 ranks will not fit on
one, so the 1-GPU failure may be a distinct fault rather than the one being chased.

## `/run.sh` traces every command to stderr

`scripts/docker/run.sh` starts with `#!/bin/bash -ex`, so the resolved command is echoed several
times before it runs. For a diagnostic workload whose output you intend to read, start the command
with `set +x;` under `--shell`, or the few lines you want are buried in trace output.
