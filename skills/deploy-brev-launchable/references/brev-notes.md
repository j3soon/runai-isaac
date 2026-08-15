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

## Other Brev CLI Behavior

- `brev ls --json` wraps its array as `{"workspaces": [...]}` and exposes `build_status`,
  `shell_status`, `health_status`, and `status` per instance. Parse that rather than the
  table, whose output carries spinner escape codes.
- `brev create` has no disk-size flag. `--min-disk` is only a *filter*, and it matches the
  instance type's configurable range rather than the size actually provisioned, so a
  filter for 200GB happily returns a type that provisions 10GB. Only a Launchable sets the
  disk, which makes `brev create --launchable <id>` the sole CLI path to a large root
  disk — and this image does not fit in the 10GB default.
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
