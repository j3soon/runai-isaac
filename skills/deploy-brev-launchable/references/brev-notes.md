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
