# Brev Deployment Notes

Operational findings from deploying the Isaac Lab (Extended) with ROS 2 image on Brev,
measured on an AWS `g6e.xlarge` (1x L40S, 4 vCPU). Read the [Brev section of that image's
guide](../../../docker/isaac-lab-ex-ros2/README.md#brev) for the deployment steps; this
file covers the failure modes the happy path does not.

## Do Not Mistake Long Provisioning for a Failure

A clean deploy takes about 30 minutes: driver install ~12 min, image pull ~16 min, then
a reboot. Throughout the first ~28 minutes every symptom looks like a broken deployment,
and all of it is normal:

- `nvidia-smi` fails with `Driver/library version mismatch`, because the 580 userspace is
  installed over the base image's still-loaded newer kernel module.
- `isaac-lab-ex-ros2.service` sits `inactive (dead)`, because its
  `ExecStartPre=/usr/bin/nvidia-smi` cannot pass yet.
- There is no container and `docker images` is empty.

Waiting is the correct action. The setup script's own `shutdown -r +1` fires once the
pull finishes, the reboot loads the 580 module, and the unit starts Compose within
seconds. Intervening destroys the evidence and can pre-empt a step the script was about
to take: a manual reboot issued ~14 minutes in looked like it "fixed" a hung deploy when
the deploy was simply mid-pull.

Check the phase rather than inferring from symptoms:

```sh
cat /var/lib/isaac-lab-ex-ros2-setup.state
# preparing -> installing-driver -> pulling-image -> rebooting -> ready
tail -f /var/log/isaac-lab-ex-ros2-setup.log
```

Two traps that make inference unreliable:

- **A partially pulled image is invisible to `docker images`**, which lists nothing until
  the pull completes. An empty result is not evidence that a pull never started; check
  `pgrep -af 'apt-get|docker compose'` instead.
- **`build_status=COMPLETED` is not a readiness signal.** Brev reports it roughly 14
  minutes before the setup script actually finishes. Wait for the `ready` phase, which
  the systemd unit writes after Compose is up.

## Prefer the Base Image's Driver Branch When the Application Allows It

The long broken-looking window above exists only because the 2.3.2 variant installs a
driver branch different from the one the base image already runs. The 3.0.0-beta2.patch1
variant pins 595, which is what Brev's base image ships, so its setup script installs no
driver and never reboots. Both measured on `g6e.xlarge`:

| | 2.3.2 (580) | 3.0.0-beta2.patch1 (595) |
| --- | --- | --- |
| driver install | ~12 min | skipped |
| reboot | yes | none |
| create to ready | ~30 min | ~24 min |
| `nvidia-smi` during setup | fails for ~28 min | healthy throughout |
| image size | ~33.9GB | ~38.7GB |

The wall-clock saving is smaller than the skipped install suggests, because the image
pull dominates and the newer image is larger. The bigger benefit is that no phase of the
deploy looks like a failure. When adding a variant, check the base image's loaded driver
first and match it if the application's tested driver allows; only downgrade when the
application genuinely requires it.

Detect the branch rather than assuming it, so the script still works if the base image
changes:

```sh
LOADED="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' /proc/driver/nvidia/version | head -1)"
[[ "$LOADED" == "$DRIVER_BRANCH".* ]] && echo "no install needed"
```

## Keep the Driver Install and the Image Pull Sequential

Overlapping them looks like free parallelism — the pull needs no GPU driver, and the
container cannot start before the reboot anyway — but it does not help on a small
instance. Measured on 4 vCPUs, running them concurrently stretched the driver install
from ~12 to ~25 minutes and the pull from ~16 to ~30, for ~33 minutes total against ~30
sequential. The DKMS build and the image decompression contend for the same cores.

## Isaac Sim 5.1.0 Really Does Fail on the 595 Driver Branch

This is why the setup scripts downgrade Brev's stock 595 to 580, and it is corroborated
upstream rather than only locally:

- [IsaacSim#537](https://github.com/isaac-sim/IsaacSim/issues/537) — driver 595.79 makes
  Isaac Sim 5.1.0 (and 6.0) fail to detect the CUDA device and crash during RTX plugin
  initialization. "Downgrading the NVIDIA driver to version 580 resolves the issue."
- [Isaac Sim 5.1.0 requirements](https://docs.isaacsim.omniverse.nvidia.com/5.1.0/installation/requirements.html)
  lists Linux **580.65.06** as the tested driver. Note it states no *maximum*, so the
  incompatibility is a known-issue matter rather than something the requirements page rules out —
  do not expect to find it documented there.

So keep the downgrade, and treat "the docs don't forbid this driver" as weak evidence either way.

## `ERROR_INCOMPATIBLE_DRIVER` Usually Means a Missing EGL Vendor File, Not a Bad Driver

A container that fails Vulkan with

```
Could not get 'vkCreateInstance' via 'vk_icdGetInstanceProcAddr' for ICD libGLX_nvidia.so.0
vkCreateInstance failed with ERROR_INCOMPATIBLE_DRIVER
```

is most likely missing `/usr/share/glvnd/egl_vendor.d/10_nvidia.json`. The NVIDIA container toolkit
injects the Vulkan **ICD**, but not the GLVND **EGL vendor** registration; without a display the
NVIDIA Vulkan ICD reaches the GPU through EGL/GBM, and that path needs the vendor registered. Add
it in the image:

```dockerfile
RUN mkdir -p /usr/share/glvnd/egl_vendor.d && \
    printf '%s\n' '{' '    "file_format_version" : "1.0.0",' '    "ICD" : {' \
      '        "library_path" : "libEGL_nvidia.so.0"' '    }' '}' \
      > /usr/share/glvnd/egl_vendor.d/10_nvidia.json
```

Images built from a desktop-driver machine's assumptions omit it silently, because a normal driver
install provides the file.

**Which bases need it** (checked across this repository, 2026-08-19):

| base | ships `10_nvidia.json`? |
| --- | --- |
| `nvcr.io/nvidia/isaac-lab:*`, `nvcr.io/nvidia/isaac-sim:*` | **yes** — inherited, nothing to do |
| `nvidia/cuda:*`, bare `ubuntu:*` | **no** — add it if the image renders |

So every image here built on an NGC Isaac base is unaffected, and the repository's `-ex` images
already write the file by hand because they start from `ubuntu`. Only an image that both starts
from `nvidia/cuda`/`ubuntu` *and* needs Vulkan is exposed. Check with:

```sh
docker run --rm <image> ls /usr/share/glvnd/egl_vendor.d/
```

 This repository's `isaac-lab-ex-ros2` image already writes it, which is
why it rendered on hosts where `hcis-lab-aicapstone` could not — the two ran on the *same* AWS host,
minutes apart, one working and one not.

**The host driver is a contributing condition, not the fault.** The gap only surfaced where Brev's
AWS base ships 595 and the setup script downgrades to Ubuntu's `nvidia-driver-580`; on shadeform,
whose base already ships 580, the same image worked without the file. So a Vulkan failure that
disappears when you change provider is not evidence the provider was broken.

**Ruled out by direct measurement on a failing host.** All of these cost real instance time and
none is the cause:

- **The Vulkan ICD JSON.** Both images carry byte-identical ICD JSON *at runtime* — the toolkit
  overwrites an image's hand-written copy, so a baked `api_version` is not what differs. Check the
  file inside a running container before theorising about it.
- **The Vulkan loader version** (LunarG 1.4.313.0 over Ubuntu 22.04's 1.3.204.1).
- **The base image and glibc.** A 24.04 base changed nothing, and a bare `ubuntu:24.04` failed too.
- **`undefined symbol: __malloc_hook` / `ErrorF` under `LD_DEBUG`.** The *working* container emits
  the identical set. Loader noise, not a fault — do not build a theory on it, as was done here.
- CUDA forward-compat libraries, `LD_LIBRARY_PATH`, `mesa-vulkan-drivers`, `VK_ICD_FILENAMES`,
  bind-mounting `libnvidia-api.so.1`.

**The method that actually found it**, after roughly $25 and four wrong conclusions: put a working
image and a failing image on the *same* host, then diff what each loads during
`LD_DEBUG=libs vulkaninfo`. The working one pulled in `libEGL_nvidia`, `libnvidia-eglcore` and
`libnvidia-egl-gbm`; the failing one did not, and the EGL vendor file was the only config
difference left. Reach for that A/B first — it is one instance and about an hour.

A rendering failure of this kind also **hangs rather than exits**: the Kit process stayed alive
20+ minutes after printing the error. Gate a watcher on a log marker, never on process exit.

## Provider Choice for Rendering Workloads

**GCP cannot run a rendering workload at all.** Its instances install a *compute-only* NVIDIA
driver: no `libGLX_nvidia`, no `libEGL_nvidia`, no `libnvidia-glcore` anywhere on the host. The
container toolkit can only inject libraries the host actually has, so no image can render there.
Verified on both a T4 and an L4 instance, and confirmed image-independent — `isaac-lab-ex-ros2` on
the same GCP host also falls back to `llvmpipe` software rendering rather than using the GPU.

**GCP does have graphics-capable SKUs, but Brev does not offer them.** Google's
[GPU documentation](https://docs.cloud.google.com/compute/docs/gpus) lists NVIDIA RTX Virtual
Workstation types — `nvidia-rtx-pro-6000-vws` (G4), `nvidia-l4-vws` (G2), and
`nvidia-tesla-t4-vws` / `-p4-vws` / `-p100-vws` (N1) — and describes them as "designed for
workloads such as **NVIDIA Omniverse simulation workloads**, graphics-intensive applications,
video transcoding, and virtual desktops". Creating a vWS instance automatically attaches a vWS
license, and that is the SKU family intended for Isaac Sim on GCP.

`brev search gpu` offers none of them. Checked 2026-08-19: every GCP accelerator Brev exposes is a
plain compute type (`nvidia-tesla-t4`, `-p4`, `-v100`, `-a100`, `nvidia-a100-80gb`,
`nvidia-h100-mega-80gb`, `nvidia-l4`), with zero `-vws` entries. So **GCP-via-Brev cannot render**,
and that is a catalogue limitation rather than a property of GCP itself. If GCP is required for a
rendering workload, provision a vWS instance outside Brev.

> Google's page does not spell out the driver-level difference, so treat the causal chain as
> inferred: what was *measured* here is that Brev's non-vWS GCP instances ship no graphics
> libraries at all.

**Confirmed by direct test, not inference.** On `g2-standard-4:nvidia-l4:1` running the
`isaac-lab-ex-ros2` 2.3.2 image:

| test | result |
| --- | --- |
| `vulkaninfo` in container | `llvmpipe` only, no NVIDIA device |
| `Isaac-Cartpole-v0`, no cameras | **passes**, 95627 fps total — but Kit logs `Driver Version: 0` |
| `Isaac-Cartpole-RGB-Camera-Direct-v0 --enable_cameras` | **fails**, killed at 450s having never completed environment setup |

`Driver Version: 0` is the tell: Kit is on software Vulkan, not the host's 580.173.02. Cartpole
still posts high fps because PhysX runs on the GPU through CUDA and the workload renders nothing.
Add cameras and PhysX drops to software too (`GPU solver pipeline failed, switching to software`).

So the GCP rows in the `isaac-lab-ex-ros2` verified-instance table are genuine cartpole numbers but
are **not** evidence of GPU rendering, and that table now carries a note saying so. A passing
non-rendering benchmark cannot validate a rendering deployment — check `Driver Version` in the Kit
log, or `vulkaninfo`, before believing a GPU is being used for graphics.

**Do not try to fix a host.** Installing `libnvidia-gl-<branch>` on a GCP instance added the
libraries and then broke the NVIDIA container toolkit outright — GPU containers stopped starting
with `/run/nvidia-persistenced/socket: no such file or directory`, which is strictly worse than the
original failure. A Brev VM should need only the driver, Docker, and a working container toolkit;
everything else belongs in the image. When a rendering workload fails, fix the container.

Measured throughput for one Isaac Sim camera-recording workload (`--num_envs 1`, two 640x480
cameras), which generalises better than a GPU ranking:

| | 12 vCPU L40S | 8 vCPU T4 | 4 vCPU L4 | 4 vCPU L40S | 4 vCPU T4 |
| --- | ---: | ---: | ---: | ---: | ---: |
| wall clock | 193s | 460s | 471s | 492s | 745s |

**vCPU count dominates, not the GPU.** The same L40S went from 492s to 193s purely on vCPUs, and an
8 vCPU T4 beat a 4 vCPU L40S. Peak VRAM was only 4.0-5.6GiB across T4/L4/L40S, so a 15GiB T4 is not
VRAM-constrained for single-environment recording. Buy vCPUs before a bigger GPU.

Shadeform `massedcompute_L40S` is the best value at $1.06/hr and skips the driver downgrade, but
budget a retry: 2 of 4 creates failed with `build_status=CREATE_FAILED` before any relay appeared,
and an immediate identical retry succeeded each time.

## Two Ways a Matrix Run Lies To You

Both cost time here, and both are cheap to avoid:

- **`grep`-ing for the vendor name misses Tesla cards.** A Vulkan probe matching
  `deviceName.*NVIDIA` reports a false failure on a T4, which identifies itself as `Tesla T4`.
  Three rows read as broken while their datagen had actually succeeded. Assert on the *workload's*
  output, not on a device-name string.
- **`pkill -f <script>` run over SSH kills the launching shell.** The `ssh host 'pkill -f rt.sh;
  ... rt.sh &'` pattern matches its own command line, so the relaunch dies instantly and every
  instance sits idle looking stalled. Match a path that cannot appear in the launcher, or do not
  pre-kill at all.

## Let the Setup Script Lose the apt Race

Brev's own provisioning runs `apt-get` concurrently with a VM setup script. A script that starts
with `set -euo pipefail` and calls `apt-get update` immediately will die on
`Could not get lock /var/lib/apt/lists/lock`, leaving the phase file at its first state — which
reads as a stalled instance rather than a failed one, and wasted an hour of billing here before it
was noticed. Wait for the lock and retry:

```sh
wait_for_apt() {
  for _ in $(seq 1 120); do
    sudo fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/lib/dpkg/lock \
      >/dev/null 2>&1 || return 0
    sleep 15
  done
}
```

## Reach the Instance Over Its SSH Relay, Not `brev exec`

`brev exec` and `brev port-forward` both target port `22`, which is firewalled on AWS
`g6e`: a direct TCP connection to `<public-dns>:22` times out, and the CLI retries until
it gives up. The failure looks like a service that never started.

- Brev's generated `~/.brev/ssh_config` (included from `~/.ssh/config`) points the bare
  instance-name alias at its relay, `global.prd.ga.run.brev.nvidia.com`, on a per-instance
  high port. Plain `ssh <instance>` and `ssh -L <local>:localhost:<remote> <instance>`
  work immediately; use those for exec and for probing forwarded services.
- That config is written only once the instance exists, so run `brev refresh` *after*
  creating it. Refreshing before creation silently leaves no host entry, and every later
  `ssh` fails with `Could not resolve hostname`.
- "After it exists" is not enough: wait until the relay itself is provisioned. For the
  first ~2 minutes after `RUNNING`, the API reports the raw `ec2-*.compute-1.amazonaws.com`
  hostname on port 22, and only later swaps in the relay host and per-instance high port.
  A `brev refresh` inside that window writes a host entry that can never connect, and the
  resulting timeout is indistinguishable from a broken instance. Poll the workspace JSON
  until `environment.ssh_access` is non-empty and `environment.instance.ssh_hostname` is
  the relay, then refresh. Measured: `RUNNING` at ~100s, relay at ~220s.
- The EC2 security group does allow port 22, but only from three Brev relay addresses, so
  a direct connection from anywhere else times out by design. `exposedPorts: []` on the
  workspace is normal and is not what blocks SSH.

## Instance Visibility Is Org-Scoped, and `brev ls` Hides Teammates

Everything in Brev is scoped to an organization, and the two list forms differ in *whose*
instances they return within that org:

- `brev ls` returns only the instances owned by the logged-in user.
- `brev ls --all` returns every instance in the org, teammates' included, plus external
  nodes. `brev ls nodes` returns the external nodes alone.

So `brev ls` printing `No instances in org <ORG>` does not mean the org is empty — it can
still hold running, billing GPU instances that only `--all` reveals. Always take the
pre-deploy inventory with `brev ls --all`, and confirm a deletion the same way.

Ownership is decided by the logged-in identity, not by the org name, so instances created
under a different identity in your own org (an agent or token session versus an
interactive login) appear only under `--all`. The `--json` payload carries no owner field
to distinguish them; check the console at <https://brev.nvidia.com> when attribution
matters.

`brev ls orgs` lists the orgs you belong to. Visibility never crosses them: there is no
"all my instances everywhere" view, so switch with `brev org set <ORG>` or query one
inline with `brev ls --all -o <ORG>`. Seeing an instance is also not access to it —
SSH into a teammate's node requires the owner to run `brev grant-ssh`.

## Creating an Instance Without a Launchable

Read the Launchable's configuration first — it is the specification to reproduce, and both
ways of reading it are free. `brev create --launchable <id> --dry-run` prints the name,
description, instance type, storage, and build mode without creating anything. For the
whole definition, including the port list and the id of its lifecycle script,
`GET /api/launchables/<id>/now` returns `createWorkspaceRequest` (`workspaceGroupId`,
`cloudCredId`, `instanceType`, `storage`) alongside `buildRequest.ports`. Neither returns
the script body; `GET /api/launchable/lifecycle-script?envId=<id>&scriptId=<ls-id>` does.

`brev create` cannot express a Launchable's disk size or port mappings, but the API it
calls can. `POST /api/organizations/<ORG>/workspaces` on
`https://brevapi.us-west-2-prod.control-plane.brev.dev`, with the CLI's bearer token from
`~/.brev/credentials.json`, accepts the whole configuration:

```json
{"name":"<NAME>","cloudCredId":"devplane-brev-1-credential",
 "workspaceClassId":"2x8","workspaceTemplateId":"4nbb4lg2s",
 "instanceType":"g6e.xlarge","diskStorage":"256Gi",
 "portMappings":{"jupyter-lab":"8888","novnc":"6080","vscode":"8080"},
 "workspaceVersion":"v1"}
```

- `workspaceVersion: "v1"` is mandatory. Omit it and the API rejects the whole request
  with `400 Legacy workspace version unsupported`, which reads like a client-version
  problem rather than a missing field.
- `portMappings` is a *name to port* map, and it is what opens the application ports.
- `cloudCredId` is per provider and must match the instance type's cloud:
  `devplane-brev-1-credential` for AWS, `brev-gcp-test` for GCP. Pairing a GCP type with
  the AWS cred fails as `500 … rpc error: NotFound desc = instance type <type> not found`,
  which points at the type rather than the real cause.
- `diskStorage` cannot go below the base image's snapshot. On AWS that is 75GB, and a
  smaller value fails the whole provision with `InvalidBlockDeviceMapping: Volume of size
  <n>GB is smaller than snapshot …, expect size >= 75GB`. Provisioning failures bill
  nothing, but they land in `FAILURE` rather than retrying.
- Do not hand-write this payload from guesswork. Point `BREV_API_URL` at a local HTTP
  server and run the real `brev create`: the CLI honors the variable, so the exact request
  body lands in your log and nothing reaches Brev. Forward `GET`s to the real host so the
  CLI's `/api/me` and `/api/organizations` preflight succeeds, and return an error for the
  `POST` so no instance is created. Running that against `--launchable <id>` dumps the
  Launchable's own create payload, which is the authoritative template to copy.
- A deleted instance holds its name until deletion finishes; reusing it immediately fails
  with `400 duplicate workspace with name <NAME>`.

The setup script attaches at create time too — put it in
`vmBuild.lifeCycleScriptAttr.script` as inline text:

```json
{"vmBuild":{"forceJupyterInstall":false,
            "lifeCycleScriptAttr":{"script":"#!/bin/bash\n…"}}}
```

No registered script id is needed. `brev create --startup-script @file` sends exactly this
field with no id and no separate registration call, and the server assigns the `ls-…` id
itself. The top-level `startupScript` field is the one to avoid: the CLI always sends it
empty, and a create that puts the script there gets it echoed back as `""`.

**Do not verify this through cloud-init.** `user_data_base64` in the provision directive
holds only the three empty cloud-init stubs (`always.sh`, `instance.sh`, `once.sh`) whether
or not a script attached — reading its emptiness as "the script was dropped" is wrong, and
cost a full redeploy here. Brev delivers the script out of band, and the evidence is on the
instance:

```bash
ls /opt/oncreate_lifecycle_script_*.sh        # the script Brev wrote and ran
ls ~/.lifecycle-script-ls-*.log               # its transcript, named with the assigned id
```

Timing matters when checking: the agent runs the script a couple of minutes *after* the
instance reports `RUNNING`, and later than `ssh_access` appears. A check at ~220s found
nothing; the same check at ~3 minutes of uptime found the script complete. Do not conclude
"no script" from one early look, and do not start applying it by hand — the Launchable-free
create in this repository's testing had its script running all along, so a manual `setsid
nohup` run raced Brev's own copy of the same script.

Measured end to end on `g6e.xlarge` with a 256GiB disk: `installing-driver` ~1 min,
`pulling-image` ~6 min, `rebooting` ~22 min, `ready` with the container up at ~24 min —
then all five service probes and both Isaac workloads pass, the same as the Launchable.

Validating two instances at once costs no more than one after the other and halves the
wall clock, since a deploy is ~23 minutes of waiting either way. Create both, then give
the second `--port-offset 10000` so its local tunnel ports do not collide. Confirmed with
an L40S and a T4 deploy running concurrently from one watcher; see the verified instance
table in `docker/isaac-lab-ex-ros2/README.md` for the per-GPU results.

When comparing GPUs this way, match RAM and disk explicitly and check the architecture.
Instance searches rank by GPU name, VRAM, and RAM, which lets an `arm64` type (AWS
`g5g.*`, carrying a T4**g**) sit next to the `x86_64` type you want with everything else
looking identical.

## Test a Watcher Before Trusting It Unattended

Three unattended watchers in one session each reported "still waiting" for 20-45 minutes
while nothing was happening. None cost money beyond idle instances, all cost wall clock,
and all were the watcher's fault rather than Brev's:

- **Expired auth reads as "not ready".** A long poll against the REST API starts returning
  `401` once the stored session expires, and a status parser turns that into "not ready
  yet". Poll `brev ls --json` instead: the CLI refreshes its own token. If a script must
  use the REST API, run any `brev` command first and re-read `~/.brev/credentials.json`,
  because the CLI rewrites the token there.
- **`grep -c READY` also matches `NOT READY`.** That declared success in 30 seconds, so
  `brev refresh` ran before any relay existed and wrote no host entries at all. Match the
  delimited field (`grep -c '|READY$'`).
- **`grep -c` prints `0` *and* exits non-zero on no-match**, so the common
  `$(grep -ci "no space left" "$LOG" || echo 0)` guard emits `0\n0` on the healthy path. That
  compares unequal to `0` and fires the abort condition immediately — a watcher that kills a
  perfectly good deploy and reads as a real disk failure. Use
  `grep -qi ... && echo NOSPACE` and test for the marker's presence rather than counting.
- **Waiting on `status=RUNNING` never succeeds during setup.** Brev reports `UNHEALTHY`
  for most of a 2.3.2 deploy because its gpu-driver health check fails until the driver
  reboot. Gate on `shell_status=READY`, which is what tracks SSH availability.

- **`build_status=CREATE_FAILED` is a distinct failure field.** A shadeform provision failed with
  `status=RUNNING`, `shell_status=NOT READY`, and `build_status=CREATE_FAILED`, so a watcher gating
  only on `status`/`shell_status` waited out its full timeout on an instance that was already dead.
  Abort on `CREATE_FAILED` and on `environment-build -> failed`, not just on `FAILURE`.
- **Provisioning failures happen and are often transient.** That same shadeform type failed to
  create once and succeeded on an immediate retry with an identical payload. One retry before
  changing anything is reasonable; treat a second identical failure as real.

Also give a watcher an abort condition, not only a success condition: check for `FAILURE`
status and grep the setup log for `no space left`. A failed create otherwise looks exactly
like a slow one for as long as the timeout allows.

## Deletion Reports `DELETING` Long After Billing Stops

Deleting is two steps, and `brev ls --all` shows `DELETING` for both. The machine is gone
once the `terminate-environment-instance` task succeeds; the `delete-environment` task
that follows only clears the control-plane record, and that took ~4 more minutes with the
name still listed. Do not read the lingering row as a failed delete and issue more delete
calls. To tell the two apart, check the tasks:

```bash
curl -s -H "Authorization: Bearer $TOKEN" "$BREV_API/api/workspaces/<ID>" \
  | python3 -c "import sys,json;e=json.load(sys.stdin)['environment'];print(e['instance']['status']);[print(t['name'],t['status']) for t in e['tasks']]"
```

`lifecycle_status: terminating` with `terminate-environment-instance: succeeded` means the
charge has stopped. Still confirm the row eventually disappears from `brev ls --all`.

**A delete can fail and leave the row as `STOPPED`, which does not look like a failure.** Two
instances here went `DELETING` for several minutes and then reverted to `STOPPED`, reading as a
deliberate stop rather than a delete that did not finish. The task list showed the real story:
`terminate-environment-instance: succeeded` — so the machine and its hourly charge were gone —
alongside `delete-environment: failed`.

That `delete-environment` failure can be **persistent and server-side**, and it exposes no error
message. Both `brev delete` (twice) and `DELETE /api/workspaces/<id>` (which returns `202
Accepted`) were retried and the task failed again each time, leaving the rows in place. So:

- Confirm deletion by **absence** from `brev ls --all`, never by a delete command succeeding.
- Treat a `STOPPED` row you did not stop as an unfinished delete.
- Retrying beyond twice is not useful once the task is failing repeatedly. Fall back to the
  console at <https://brev.nvidia.com>, or contact Brev, rather than looping.

What this does *not* establish is an ongoing charge. Once `terminate-environment-instance`
succeeds the instance is terminated, and an EC2 root volume is normally deleted with its
instance, so a stale row is most likely bookkeeping rather than billing. Verify in the console
before assuming either way; do not report a cost you have not confirmed.

## Other Brev CLI Behavior

- `brev ls --json` wraps its array as `{"workspaces": [...]}` and exposes `build_status`,
  `shell_status`, `health_status`, and `status` per instance. Parse that rather than the
  table, whose output carries spinner escape codes.
- `brev create` has no disk-size flag. `--min-disk` is only a *filter*, and it matches the
  instance type's configurable range rather than the size provisioned, so a filter for
  200GB tells you nothing about what you get. What `create` actually requests is
  `diskStorage: "120Gi"`, hardcoded in CLI v0.6.334 — *not* the `TARGET_DISK` value the
  `brev search` table shows for the type (10 for `g6e.xlarge`). 120GiB does fit this
  image. Confirm the request rather than reading it off the search table, and confirm the
  result with `df -h /` on the instance.
- A Launchable is not the only way to set the disk. The console's instance-creation page
  offers "Choose disk size", and the API takes `diskStorage` directly — see the section on
  creating without a Launchable below.
- `brev login --token <sso-token>` is good for one short window: the token expires in ~15
  minutes and the stored session lasts a few hours at most. A long deploy can outlive its
  own credentials, leaving a running GPU instance that cannot be deleted until the next
  login. Re-check authentication before starting anything long.

## Verify a GPU Workload, Not Just the Ports

All five services can answer while Isaac Sim cannot initialize, since Kit additionally
needs GPU passthrough and Vulkan inside the container. Check the driver, the service, and
Compose first:

```sh
nvidia-smi
sudo systemctl status isaac-lab-ex-ros2.service
sudo docker compose --project-name isaac-lab-ex-ros2 \
  -f /opt/isaac-lab-ex-ros2/compose.yaml \
  -f /opt/isaac-lab-ex-ros2/compose.override.yaml ps
```

Then run something on the GPU:

```sh
sudo docker exec <container> /root/isaacsim/python.sh -c \
  "from isaacsim import SimulationApp; a=SimulationApp({'headless': True}); print('OK'); a.close()"
sudo docker exec <container> bash -lc \
  "cd /root/IsaacLab && ./isaaclab.sh -p -u scripts/reinforcement_learning/rl_games/train.py \
   --task=Isaac-Cartpole-v0 --headless --max_iterations=3"
```

[`../scripts/launchable_test.sh`](../scripts/launchable_test.sh) runs this whole sequence
unattended, including the service probes over an `ssh -L` tunnel.

## `WORKSPACE_DIR` Mounts the VM Root on Brev

`WORKSPACE_DIR` defaults to `../..`, relative to the Compose file. That is the repository
root when running from a clone, but the setup script installs the Compose file at
`/opt/isaac-lab-ex-ros2/`, where `../..` resolves to `/` and mounts the whole VM root into
the container read-write. Set `WORKSPACE_DIR` explicitly on Brev if that is not what you
want.

## `brev delete` Cannot Remove Teammates' Instances — the REST API Can

`brev delete <name-or-id>` only resolves instances the **logged-in account owns**. For an
instance created by anyone else it exits non-zero with

```
delete.handleAdminUser: instance with id/name <id> not found
```

`not found` is misleading — the instance exists and `brev ls --all` lists it. The lookup is
ownership-scoped, and there is no `--all`, `--org`, or admin flag on `brev delete` to widen it.
Being `OrganizationAdmin` does not change the CLI's behaviour.

**This is a CLI limitation, not a permissions one.** The REST API deletes another member's
instance fine for an org admin, returning `202 Accepted`:

```sh
TOK=$(jq -r .access_token ~/.brev/credentials.json)
H=https://brevapi.us-west-2-prod.control-plane.brev.dev
curl -s -X DELETE -H "Authorization: Bearer $TOK" "$H/api/workspaces/<INSTANCE_ID>"
```

Only the flat `/api/workspaces/<id>` route exists; the org-scoped
`/api/organizations/<ORG_ID>/workspaces/<id>` variant is a 404.

**Do not infer capability from the role's action list.** Querying the role attachments shows
`OrganizationAdmin` granting only `CreateWorkspaces` and `ViewWorkspaces`, with no workspace
delete or modify action anywhere — which reads as "admins cannot delete other people's
instances" and is wrong. The enforced permission is broader than the advertised action list.
Verify with one real call against a single instance instead of concluding from this output:

```sh
curl -s -H "Authorization: Bearer $TOK" "$H/api/users/<YOUR_USER_ID>" \
  | jq -r '.roleAttachments[] | select(.object|startswith("org-")) | "\(.object)\t\(.role.id)\t\(.role.actions|join(","))"'
```

Deletion is asynchronous: instances sit at `DELETING` for roughly 2–4 minutes before
disappearing from the org listing. Poll rather than assuming the `202` finished the job.

**The access token expires in well under an hour**, and a long poll loop will start returning
`{"errors":[{"type":"UnauthorizedError"}]}` mid-run, which is easy to misread as the instances
becoming inaccessible. Any `brev` CLI command refreshes `~/.brev/credentials.json`; re-read the
token afterwards.

Useful counterpart: the org-scoped REST route returns every instance with owner and creation
time, which `brev ls --all` omits (its JSON carries only `id`, `name`, `status`, `instance_type`,
`gpu`, `build_status`, `health_status`, `instance_kind`):

```sh
curl -s -H "Authorization: Bearer $TOK" "$H/api/organizations/<ORG_ID>/workspaces" \
  | jq -r '.[] | [.id, .name, .createdByUserId, .createdAt, .status] | @tsv'
curl -s -H "Authorization: Bearer $TOK" "$H/api/users/<USER_ID>" | jq -r '.email'
```

Use it to identify owners and instance age **before** proposing a bulk delete — a set of
instances created within a couple of hours of each other by many distinct users is a live
workshop, not leftover resources. Confirm the session has ended before destroying anything.

## `brev delete` Reads stdin, Which Breaks `while read` Loops

`brev delete` is pipeable (`echo instance-name | brev delete`), so it consumes stdin when none
is redirected. Inside a `while IFS= read -r ... done < list.txt` loop it swallows every
remaining line of the list on the first iteration, then reports each swallowed line as a
separate `not found` error and the loop ends after one pass. The failure looks like a
permissions problem and hides how many targets were actually attempted.

Redirect stdin per invocation:

```sh
while IFS=$'\t' read -r name id; do
  brev delete "$id" </dev/null || echo "FAIL $name"
done < targets.tsv
```

The same applies to `brev stop`/`brev start`. Prefer passing several names in one call
(`brev delete a b c`) or a `for` loop over an array when the list is already in memory.
