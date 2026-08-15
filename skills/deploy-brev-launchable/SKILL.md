---
name: deploy-brev-launchable
description: Deploy and validate an NVIDIA Brev Launchable for this repository's images, including instance creation, waiting out long provisioning without intervening, SSH access over Brev's relay, service and GPU-workload verification, and billed cleanup. Use for Brev VM-mode deployments such as Isaac Lab (Extended) with ROS 2, or when a Brev instance appears broken during setup. Do not use for Run:ai workloads, which belong to the `launch-runai-workload` skill.
---

# Deploy Brev Launchable

Take a Launchable from deployment to verified services and a real GPU workload, on an
instance that bills by the hour. Prefer observing to intervening, and delete what you
create.

Read [references/brev-notes.md](references/brev-notes.md) before the first deployment. It
records the measured timeline and the failure modes that have each produced a wrong
conclusion before: a healthy mid-setup instance read as broken, a provider status field
mistaken for readiness, and an SSH path that cannot work.

## 1. Establish the deployment contract

- Resolve the Launchable ID, instance type, hourly price, expected duration, and who
  deletes the instance.
- Record the existing instances with `brev ls --all` and treat every one of them as
  out of scope. Never stop, start, reset, or delete an instance this task did not create.
  Use `--all`, not plain `brev ls`, which returns only your own instances and so can
  report an empty org that is in fact running billed GPU instances.
- Prefix instance names so yours are identifiable, and confirm the cost before creating
  anything. A GPU instance keeps billing whether or not anyone is watching it.
- Record `git status --short`; never change the Git index unless explicitly requested.

## 2. Preflight

- Confirm the CLI and authentication: `brev --version`, then any read-only command.
- `brev login --token <sso-token>` buys one short window. The token expires in about 15
  minutes and the stored session lasts a few hours at most, so a deploy can outlive its
  own credentials and leave a running instance that cannot be deleted until the next
  login. Re-authenticate before starting anything long, not after.
- Do not start a create you cannot finish supervising. Losing auth mid-deploy is how an
  instance becomes an unattended charge.

## 3. Deploy

- Deploy as a Launchable: `brev create <name> --launchable <id>`. The Launchable carries
  the instance type, disk size, and setup script.
- Do not substitute `brev create --startup-script`. There is no disk-size flag, so it
  provisions the small default and a large image will not fit; `--min-disk` is only a
  filter and matches the type's configurable range, not the size provisioned.
- Use `--dry-run` to confirm the resolved instance type and storage for free before
  spending anything.
- Editing the repository's setup script does not change an existing Launchable. The
  Launchable holds its own copy, so a script change must be pasted into the console
  before it can be tested.

## 4. Wait without intervening

This is the step that goes wrong. A clean deploy of a simulator image takes roughly half
an hour, and for most of that it presents exactly like a broken one: a failing
`nvidia-smi`, an inactive service, and no container. All of it is normal until the setup
script's own reboot.

- Watch the setup script's phase file rather than inferring from symptoms. Wait for the
  phase the unit writes after the application is actually up.
- Treat the provider's build/status field as a start signal, not a readiness signal; it
  reports success well before the setup script finishes.
- A partially pulled image is invisible to `docker images`. An empty list is not evidence
  that nothing is happening; check for running work instead.
- Do not reboot, start services, or "fix" a driver mismatch during setup. Doing so
  destroys the evidence and can pre-empt a step the script was about to take on its own.
- If it genuinely stalls, capture state first: boot time, phase file, setup log, running
  processes, and service status. Report those before changing anything.

## 5. Access over the SSH relay

- `brev exec` and `brev port-forward` target port 22, which is firewalled on some
  instance types; they hang and then fail in a way that looks like a dead service.
- Use the alias in Brev's generated `~/.brev/ssh_config`: plain `ssh <instance>` for
  commands and `ssh -L <local>:localhost:<remote> <instance>` for services.
- Run `brev refresh` *after* the instance exists. Refreshing earlier writes no host entry,
  and every later `ssh` fails to resolve the name.

## 6. Verify services and a real workload

- Probe each exposed service through one tunnel, accepting a redirect or auth challenge
  as success, and confirm the response really is that service rather than only a status
  code.
- Then run an actual GPU workload. Every port can answer while the simulator cannot
  initialize, because it additionally needs GPU passthrough and Vulkan inside the
  container. Ports alone are not evidence the deployment works.
- [scripts/launchable_test.sh](scripts/launchable_test.sh) performs the whole sequence
  unattended and writes evidence under the gitignored `artifacts/` tree:

```bash
<skill-dir>/scripts/launchable_test.sh --launchable <id> [--name <name>] [--delete]
<skill-dir>/scripts/launchable_test.sh --existing <name> [--skip-workload]
```

- Prefer `--delete` on validation runs. An instance kept "just to look at" bills until
  someone remembers it, and a lost session cannot clean up after itself.
- The local tunnel ports are fixed, so two runs at once collide. Pass `--port-offset
  10000` to the second when validating two Launchables concurrently; deploys are long
  enough that running them in parallel costs no more in total.

- Do not edit or move a script while a run is executing it. Renaming is safe, but
  rewriting its contents shifts the byte offsets the shell is still reading and the run
  dies mid-token.

## 7. Clean up and report

- Delete the instance as soon as verification is complete unless the user asked to keep
  it, and say what it cost. An idle GPU instance is a silent charge.
- Prefer `--delete` on validation runs so a lost session cannot orphan an instance;
  confirm removal with `brev ls --all` rather than assuming.
- Report the Launchable, instance type and price, elapsed phases, service and workload
  results, anything left running, and any check that did not actually execute.
