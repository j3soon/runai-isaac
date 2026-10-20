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

Waiting is the correct action. The setup script's scheduled reboot fires once the
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

## AWS DLAMI Can Block Driver Installation

A 2026-10-19 report, reproduced with the original AICapstone setup script on a fresh AWS
`g6e.xlarge` on 2026-10-20, found that a newer Brev AWS DLAMI base carries
`/etc/apt/preferences.d/00-dlami-block-nvidia-driver`. It gives `nvidia-driver*`,
`kmod-nvidia*`, and `nvidia-kmod*` apt priority `-1`, so the 580 install fails with:

```
Package 'nvidia-driver-580' has no installation candidate
```

This differs from the temporary driver/library mismatch during a healthy setup. The script
has exited at `installing-driver`, the original 595 driver remains loaded, and no image pull
or reboot follows. Capture the setup log, running apt/dpkg processes, the preference file,
and `apt-cache policy nvidia-driver-580` before intervening. A `Candidate: (none)` with
available versions at priority `-1` identifies the package-policy block. Retrying apt or
renaming the package to `nvidia-open-580` cannot bypass its blocked driver dependencies.

The AICapstone and Isaac Lab 2.3.2 setup scripts remove only this AWS DLAMI preference in the
driver-change branch, refresh apt metadata, then install the existing 580 package. Removal
with `rm -f` also tolerates an absent AWS preference file. A host already running 580 skips
this branch and retains its NVIDIA packages and preferences.

The report verified a manual install and a fresh AICapstone deployment reaching `ready` on
580.178.04. That is setup evidence, not a rendering or dataset check. A provider sweep must
also verify NVIDIA Vulkan (`vendorID = 0x10de`), run camera-enabled datagen, and inspect the
exported dataset and videos. Do not count `nvidia-smi` or `ready` alone as application success.

The 2026-10-20 sweep subsequently passed those workload checks across six providers,
including AWS after the additional CDI repair below. See the dated
[AICapstone results](#aicapstone-driver-regression-validation-2026-10-20)
for driver versions, instance types, exported frame counts, and validation scope.

Update the Launchable's saved script before a fresh test; it does not follow repository edits.
Preserve existing instances, and delete the test VMs once their evidence has been collected.

## Older Packaged Drivers Can Block a Branch Change

The 2026-10-20 provider sweep found two additional obstacles on Crusoe's Ubuntu 22.04 base,
which starts on driver 565.57.01. Removing the AWS preference alone cannot address them:

- **Installed driver packages are held.** Apt finds a 580 candidate but cannot replace
  `nvidia-driver-565`, its DKMS/kernel packages, and related utilities. Release holds only on
  installed driver components before changing branches. Do not unhold every `nvidia-*` package:
  this base also holds the container toolkit, and hundreds of uninstalled package names.
- **An obsolete graphics package owns a file that moved.** Even after releasing the holds,
  installing CUDA-repository `libnvidia-gl-580` fails because
  `/usr/lib/x86_64-linux-gnu/gbm/nvidia-drm_gbm.so` still belongs to `libnvidia-extra-565`.
  Remove installed `libnvidia-extra-*` packages from older branches before the 580 install.
  Apt had left this package installed as an unused dependency; resolving dependencies alone
  did not predict the subsequent dpkg file collision.

Capture the failed setup log, `apt-mark showhold`, installed package status, and apt policy
before changing anything. These are separate failures from `Candidate: (none)`, and an apt
retry cannot fix either. Preserve the container-toolkit holds. Hosts already running 580
skip all of these changes.

## `shutdown` Can Return Success Without Scheduling a Reboot

On Lambda's Ubuntu 22.04 base (2026-10-20), `/usr/sbin/shutdown` resolves through an
alternative to `shutdown.lambda`. That wrapper only broadcasts a notice about terminating
instances in the provider console. It ignores `-r +1` and returns success, so setup reports
completion but stays at `rebooting`: the old 570.148.08 kernel module remains loaded against
new 580 userspace, and `nvidia-smi` reports an NVML version mismatch.

Check `readlink -f /usr/sbin/shutdown`, the setup log, boot ID, the pending shutdown schedule,
and the shutdown journal before intervening. An empty schedule alone does not prove failure;
pair it with the unchanged boot and loaded module after the scheduled time has passed.

The AICapstone and Isaac Lab 2.3.2 scripts instead schedule a systemd timer that invokes
`/usr/bin/systemctl reboot` after one minute. This preserves Brev's window to record setup
completion and uses the normal reboot path rather than Lambda's `shutdown.lambda` wrapper.
Verified on that Lambda VM: the boot changed, driver 580.119.02 loaded, and the ready unit
succeeded without a manual reboot.

For the updated scripts, inspect `systemctl list-timers aicapstone-reboot.timer --all`
(or `isaac-lab-ex-ros2-reboot.timer`), not just `/run/systemd/shutdown/scheduled`. The timer
is transient and disappears on reboot; confirm the new boot ID and loaded module afterward.

## CDI Specifications Can Retain Removed Driver Paths

Later AWS and GCP deployments in the 2026-10-20 sweep exposed a second post-reboot failure:
host `nvidia-smi` reported 580.178.04 and setup reached `ready`, but GPU containers failed
before their entrypoint with `open /usr/lib/x86_64-linux-gnu/libcuda.so.595.91.07: no such
file or directory`. The runtime was in CDI mode and `/etc/cdi/nvidia.yaml` still referenced
the removed 595 libraries. This is different from a loaded-module/userspace mismatch.

Capture `systemctl cat nvidia-cdi-refresh.service`, its boot journal, the runtime's
`config.toml`, and CDI files in `/etc/cdi` and `/var/run/cdi` before changing them. On these
hosts, Brev's local refresh unit declared `After=docker.service` and restarted Docker in
`ExecStartPost`. NVIDIA Container Toolkit 1.20.1 added its `10-container-engines.conf` drop-in declaring
`Before=docker.service`. Systemd reported an ordering cycle and skipped refresh, leaving
the old specification intact. An earlier GCP VM in the same sweep had passed; provider
identity and a healthy host driver do not establish container readiness.

The two 580 setup scripts detect this combination of Brev's local unit and NVIDIA's drop-in, then mask only
the conflicting drop-in with an empty file of the same name under `/etc/systemd/system/`.
This is the override mechanism described in NVIDIA's packaged drop-in itself. Their application
units wait for any queued CDI refresh and regenerate an existing `/etc/cdi/nvidia.yaml`
after `nvidia-smi` passes, before publishing readiness or starting Compose. Hosts without
that Brev CDI file skip regeneration. Do not generate against a half-installed driver:
wait for the new module to load after reboot.

Recovery on both affected VMs restored container `nvidia-smi` and NVIDIA Vulkan. A subsequent
controlled AWS reboot with the final units completed refresh and readiness automatically,
with no ordering cycle in the new boot journal. The generated units also passed
`systemd-analyze verify` before that reboot.
A fresh GCP 8-vCPU L4 deployment with the CDI repair also installed 580, rebooted, refreshed
the specification, and passed container GPU/Vulkan checks without manual recovery. Its new
boot journal had no ordering cycle and the specification referenced the loaded 580 libraries.
Its camera-enabled datagen then passed in 492s, with two exported episodes, 1010 parquet
rows, and 1010 decoded frames in each camera stream. A final setup-script rerun preserved
the boot, package holds, and image identity and rechecked NVIDIA Vulkan successfully.

[NVIDIA's CDI documentation](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/cdi-support.html)
describes service-triggered and direct `nvidia-ctk cdi generate` regeneration, and notes
that driver removal is not automatically handled. Refresh the specification matching the
runtime configuration; do not leave conflicting copies in both CDI directories. Require
container `nvidia-smi`, NVIDIA Vulkan, and the actual camera workload after recovery.

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

**Recheck the base image rather than treating a provider as permanently compute-only.** On
2026-10-20, a fresh GCP `g2-standard-4:nvidia-l4:1` started on 595.91.07. The AICapstone
setup installed the full 580.178.04 driver stack and rebooted; container `vulkaninfo` then
reported NVIDIA L4 with `vendorID = 0x10de`. The older claim that GCP-via-Brev cannot render
was too broad. Brev still listed no `-vws` types in that sweep, so their absence alone is
not evidence that NVIDIA Vulkan is unavailable.

The camera-enabled AICapstone cup-stacking run then completed in **781s**, exporting two
episodes / 1010 parquet rows and 1010 decoded frames in each camera MP4. This is rendering
and dataset evidence for that setup, beyond the Vulkan probe.

The **2026-08-19** GCP failures remain valid historical measurements. Those T4/L4 hosts
already ran 580, so setup skipped installation. They had no `libGLX_nvidia`, `libEGL_nvidia`,
or `libnvidia-glcore` for the container toolkit to inject. Both AICapstone and the
`isaac-lab-ex-ros2` image fell back to software rendering or failed graphics initialization.
On the L4 with the ROS 2 image:

| test | August 2026 result |
| --- | --- |
| `vulkaninfo` in container | `llvmpipe` only, no NVIDIA device |
| `Isaac-Cartpole-v0`, no cameras | **passes**, 95627 fps total, but Kit logs `Driver Version: 0` |
| `Isaac-Cartpole-RGB-Camera-Direct-v0 --enable_cameras` | **fails**, killed at 450s before environment setup completed |

`Driver Version: 0` identifies software Vulkan. PhysX can still use CUDA for a task without
cameras, so a passing non-rendering benchmark cannot validate graphics. Check NVIDIA Vulkan,
then run a camera workload and inspect its recorded output.

A partial graphics-package repair on an August GCP host also broke GPU container startup
with `/run/nvidia-persistenced/socket: no such file or directory`. That does not establish
that a complete driver install and reboot cannot work. Prefer the setup script's complete
driver path and validate the container toolkit after reboot; keep application fixes in the
image. Do not generalize an old base-image failure into a permanent provider restriction.

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

- **Matching only `NVIDIA` in the GPU name misses Tesla cards.** A Vulkan probe matching
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
- A successful create response puts the workspace ID in top-level `id`, not
  `environment.id`. Record the intended name before the POST and save the response. If an
  ID parser fails after HTTP 201, reconcile that name with `brev ls --all --json` instead
  of creating another billed VM.

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
- **A REST create can still receive 401 after a successful CLI read.** Observed twice in
  the October sweep. Run `brev ls --all --json` again, re-read the stored token, and retry
  the rejected request. Both retries succeeded. Keep this separate from an ambiguous
  timeout: reconcile the intended instance name before retrying a create whose outcome
  is unknown, to avoid duplicate billed VMs.
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

After successful removal, `GET /api/workspaces/<id>` can return HTTP 500 with an embedded
`rpc error: code = NotFound` / `environment not found`, rather than HTTP 404 (measured
2026-10-20). A watcher that recognizes only 404 will keep counting a deleted VM as active.
Confirm absence from a successful `brev ls --all --json` response instead.

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

### Read Kit's detailed log during camera startup

The AICapstone stdout log is largely warning-level output. It can stop printing while
Isaac Sim's tasking threads are busy compiling ray-tracing pipelines. Read the path in
`[carb] Logging to file:` and inspect that file inside the running container. In the
2026-10-20 GCP L4 run, the detailed log reported
`Waiting for RtPso async group async compilation` every five seconds while stdout was quiet.
This identifies the current phase; it does not prove compilation will finish. Keep a bounded
workload timeout and require a nonempty dataset with decoded camera frames before calling
the provider supported. A working NVIDIA `vulkaninfo` probe alone does not validate cameras.

That 4-vCPU L4 run eventually passed in 781s. Its detailed log had already spent more than
six minutes waiting for shader compilation before the camera environment came up. CPU
activity and the full Kit log distinguish this cold startup from an early graphics error;
do not equate a quiet warning-level stdout log with a dead simulator.

A later 8-vCPU L4 run passed in 485s with the same two episodes / 1010 frames per camera.
These are individual cold-start smoke runs; toolkit configuration and startup caches also
varied, so the timings do not isolate a CPU scaling ratio.

### Keep machine-readable probes separate from container banners

CUDA images can print their entrypoint banner before a Python JSON result. That made a
collector's `json.loads(stdout)` fail even after its dataset checks had passed during the
2026-10-20 sweep. For metadata-only probes, use `docker run --rm --entrypoint python
<image> ...` so stdout contains the requested payload. Preserve raw output and the probe's
exit code when diagnosing parsing failures; a collector error is not a workload result.

### Frame the recorded scene before asserting on image variance

Isaac Lab 2.3.2's RGB Cartpole task defaults to a viewer at `(20, 20, 20)`.
With only 32 environments, its video shows tiny cartpoles on a nearly uniform
floor. The October saved-Launchable test decoded valid videos but initially
rejected them with a whole-frame standard-deviation threshold. Inspect a frame
before attributing that check to a GPU failure. For a useful smoke-test video,
frame environment 0 explicitly with `env.viewer.origin_type=env`, an eye near
`[3.0,3.0,3.0]`, and a target near `[0.0,0.0,2.0]` (the cartpole's spawn height).
These are workload recording options, not changes to the saved Launchable.
Keep the initial output and the corrected recording when retrying the check.

### Check services, then exercise the GPU

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

## AICapstone Driver Regression Validation (2026-10-20)

Seven single-GPU configurations across six providers passed `HCIS-CupStacking-SingleArm-v0` with `--num_envs 1 --num_demos 3 --headless --enable_cameras --record --use_lerobot_recorder`. Each result required a healthy host/container driver, NVIDIA Vulkan, an active NVIDIA device in Kit's log, nonempty parquet data, and fully decoded front/wrist camera videos at 640x480. The frame counts below match both parquet rows and each camera stream.

All used image digest `sha256:813e073bb507bdf3af8567951865a9c3ed5f0a1d50ba3604561a50a2362519dc` and AICapstone commit `9dd61f693f2db770338ce84fdd232dd7040c9555`. These are individual cold-start smoke timings, including shader compilation and export, rather than steady-state throughput benchmarks.

AWS, GCP, and Nebius used 256GiB disks. Fixed provider disks stayed at their catalog sizes: 128GB on Crusoe, 625GB on shadeform, and 1400GB on Lambda.

| Cloud | Instance | vCPU | Loaded driver | Episodes / frames | Datagen |
| --- | --- | ---: | --- | ---: | ---: |
| GCP | `g2-standard-4:nvidia-l4:1` | 4 | 580.178.04 | 2 / 1010 | 781s |
| GCP | `g2-standard-8:nvidia-l4:1` | 8 | 580.178.04 | 2 / 1010 | 485s |
| shadeform | `massedcompute_L40S` | 12 | 580.126.09 | 2 / 1010 | 198s |
| Lambda | `gpu_1x_a10` | 30 | 580.119.02 | 2 / 1010 | 210s |
| Crusoe | `l40s-48gb.1x` | 8 | 580.178.04 | 2 / 1010 | 272s |
| Nebius | `gpu-l40s-a.1gpu-8vcpu-32gb` | 8 | 580.173.02 | 1 / 505 | 332s |
| AWS | `g6e.xlarge` | 4 | 580.178.04 | 2 / 1010 | 504s |

The sweep reproduced the AWS apt block, Crusoe holds/file collision, Lambda reboot wrapper, and later AWS/GCP stale CDI specification described above. The final AWS units also passed a subsequent reboot without the CDI ordering cycle. Setup revisions and raw results are recorded under `artifacts/hcis-lab-aicapstone/raw/evidence/brev-driver-580/20261020t060802z/`; earlier provider runs preceded the later CDI fix. Diagnosis and repair steps are recorded in the troubleshooting sections above.

An additional fresh 8-vCPU GCP deployment with the CDI repair reached `ready` and passed the same camera workload without manual recovery: two episodes / 1010 frames in 492s. Final-script reruns on AWS and both 8-vCPU GCP VMs preserved their boot IDs, package holds, and image IDs while NVIDIA Vulkan remained healthy.

This covers one suitable instance per single-GPU provider, with an extra GCP CPU configuration. Launchpad and SFCompute exposed only multi-GPU choices in the filtered catalog and were outside this budgeted sweep; shadeform coverage is the Massed Compute backend. Episode counts vary with domain randomization and the [final-episode export bug](../../../docker/hcis-lab-aicapstone/README.md#--num_demos-n-exports-only-n-1-episodes).

## Validate the Saved Launchable Without Replacing Its Script

Use `brev create <test-name> --launchable <id> --type <instance-type> --detached`
for a provider sweep of the maintained Launchable. Change only the test name and
instance selection; omit `--startup-script`, `--param`, disk edits, and Compose
patches. The CLI resolves the Launchable's saved lifecycle script into the create
request itself, so an inline script in the resulting API payload does not imply
that the tester replaced it. Preserve that request and compare its script with
`GET /api/launchable/lifecycle-script?envId=<id>&scriptId=<script-id>`.

On the VM, Brev writes both `/opt/oncreate_lifecycle_script_<id>.sh` (its wrapper)
and `/opt/oncreate_lifecycle_script_user_<id>.sh` (the user's saved script). Hash
the **user** file when verifying an unchanged deployment; concatenating both files
cannot match the saved script. Keep the Launchable's default disk request even
when the selected cloud supplies a fixed disk size, and report the actual size.

Availability is a snapshot: on 2026-10-20 at about 13:07 UTC, AWS GPU types were
absent from both the public and organization catalogs, despite appearing earlier
that day. Record an unavailable provider separately from a failed driver test;
never substitute a previous hourly price for a current quote.

Avoid launching several CLI deletion processes at once: the CLI performs multiple
organization and workspace lookups per delete. Five concurrent deletes in this
test all failed with `rate limit exceeded` before deleting anything. Check each
result and inventory; use sequential deletes or the documented single-request
REST delete for recorded test IDs, and keep polling until those IDs disappear.

## Saved 2.3.2 ROS 2 Launchable Validation (2026-10-20)

After the maintainer saved the fix, the repository's 2.3.2 Launchable passed on
five available single-GPU providers. Deployments used `--launchable` and only
changed the instance selection and test name. No startup-script override,
parameter override, manual setup rerun, Compose patch, or manual reboot was used.
The saved script and every executed user script had SHA256
`3096bd469a92f3d23e77de0dfa719e6cd590f832b4b86d87fe0fd8f85ae6c239`.
All pulled `j3soon/runai-isaac-lab-ex:2.3.2-ros2-jazzy`, digest
`sha256:4c1dafafda55e5c1e84457031e514afe58057749bc7bc3c4f579d77375acae06`.

| Cloud | Instance | Loaded driver | First observed ready | Result |
| --- | --- | --- | ---: | --- |
| GCP | `g2-standard-4:nvidia-l4:1` | 580.178.04 | ~19 min | pass |
| shadeform (Massed Compute) | `massedcompute_L40S` | 580.126.09 | ~8 min | pass |
| Lambda | `gpu_1x_a10` | 580.119.02 | ~14 min | pass |
| Crusoe | `l40s-48gb.1x` | 580.178.04 | ~11 min | pass |
| Nebius | `gpu-l40s-a.1gpu-8vcpu-32gb` | 580.173.02 | ~20 min | pass |

Each pass required all five identified services (JupyterLab, VS Code, noVNC, VNC,
container SSH), host/container GPU checks, NVIDIA Vulkan, an active NVIDIA GPU
in Kit's log, ROS 2 Jazzy pub/sub, three iterations of `Isaac-Cartpole-v0` with
512 environments, and three iterations of `Isaac-Cartpole-RGB-Camera-Direct-v0`
with 32 environments. Each final camera video decoded all 61 frames, and its
sampled application-recorded image was inspected. GCP's cold camera startup took
about ten minutes, mostly shader compilation; a 450-second timeout would have
rejected this working configuration. No CDI ordering cycle appeared in the five
passing boots. GCP, Crusoe, and Lambda rebooted automatically; shadeform and
Nebius kept their existing 580 drivers.

The default disk request stayed at 256GiB. Crusoe, shadeform, and Lambda supplied
fixed 128GB, 625GB, and 1400GB disks respectively. AWS GPU types were absent from
both catalogs and repeated later searches, so this saved-Launchable sweep does
not validate AWS. Launchpad, OCI, and SFCompute exposed only multi-GPU choices
in the filtered catalog and were excluded from the budgeted sweep.

The first shadeform and Crusoe recording checks rejected the wide default viewer
as described above. Crusoe passed a recording retry on the same untouched VM;
shadeform passed a fresh identical Launchable deployment. Initial results remain
in the evidence. This validates the ROS 2 Launchable, including a camera workload;
it does not repeat AICapstone's cup-stacking datagen inside this different image.
Raw evidence is under
`artifacts/brev-saved-launchable/raw/evidence/defaults/20261020t131000z/`.
All six test VMs, including the first shadeform attempt, were confirmed absent
from the final inventory. Estimated compute/storage cost was $2.82.
