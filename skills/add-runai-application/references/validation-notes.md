# Validation Notes

Pitfalls found while building and validating Docker-backed applications in this repository. Each
one produced a wrong conclusion at least once, so check against it before reporting a result.

## Capture simulator video and screenshots in-app, not by screen capture

`ffmpeg -f x11grab` records solid black for an Isaac Sim window, even when the GUI is mapped and
rendering correctly.

Isaac Sim presents its viewport through a Vulkan swapchain, while `x11grab` reads via `XGetImage`
on the root window, which cannot see that surface under a compositing desktop. `xwd -root` is black
for the same reason, so this is not a window-geometry or offset mistake.

**Stills are affected identically.** Reach for this note whenever a screenshot comes back black,
blank, or as a zero-byte PNG — `xwd -root`, `xwd -id <window-id>`, `import`, and piping any of them
through `convert` all read the same X surface and hit the same wall, whether run on the host or
from a throwaway container sharing `/tmp/.X11-unix`. `xwininfo` reporting a correctly sized, mapped
window is not evidence that a capture of it will contain pixels. Confirming a GUI *exists* via
`xwininfo` is fine; do not spend attempts trying to photograph it.

Use the application's own recorder instead: it is headless, higher quality, and needs no X server.
RoboLab's `examples/run_gripper_toggle.py --headless` and its policy runners write per-episode
sensor and viewport MP4s; Isaac Lab has a `--video` flag. If a genuine screen recording is
unavoidable, capture through the compositor (GNOME's `org.gnome.Shell.Screencast` D-Bus interface
or a PipeWire portal grabber) rather than `x11grab`.

Verify recordings by content, not exit code. A blank clip is a few KB while a real scene is
hundreds of KB or more; `ffprobe` for frame count plus an extracted frame settles it in seconds.

That check matters most where the recorder fails silently. On Isaac Lab 3.x, `--video` alone is not
enough and has two distinct failure modes. Without `--enable_cameras` the run aborts on the first
step with `ModuleNotFoundError: No module named 'omni.replicator'`, which is at least loud. With
`--enable_cameras` but no visualizer backend, the run exits 0 and writes a structurally valid MP4
containing only an empty viewport — an all-black first frame followed by a uniform light-gray
background. Isaac Lab 3.x populates a viewport only when a `--visualizer` / `--viz` backend is
active, and `env.render()` captures that viewport, so cameras alone load the render extensions with
nothing to capture. Pass `--enable_cameras --viz kit` together. `--headless` is deprecated in this
release; headless is the default when no `--viz` backend is requested.

## A buffered policy server looks hung

Python buffers stdout when it is not a TTY, which hides *readiness banners*. A policy server such
as Isaac-GR00T's `run_gr00t_server.py` finishes loading and starts listening, but its
"Server is ready" line stays in the pipe buffer, so a healthy server appears stuck at
`Loading checkpoint shards` and gets killed.

Always pass `-e PYTHONUNBUFFERED=1` to `docker run`, or bake it into the image. Confirm readiness
from the socket (`ss -ltn | grep <port>`) rather than from the log alone.

## Pass tokens by environment variable, never store them

Gated model downloads need credentials, and batch workloads cannot log in interactively.

- Set `HF_TOKEN` as a workload environment variable, or pass `-e HF_TOKEN=...` to `docker run`.
  `hf auth login` is interactive and cannot work in a non-interactive workload. Do not set both
  with different tokens.
- Never write a token into a file in the repository, a log, or an artifact. Stage it in a
  mode-600 file on tmpfs (`/run/user/<uid>`), pass it with `docker --env-file`, and destroy it
  afterwards. A token pasted into a terminal or chat should be rotated.
- Confirm access cheaply before a long download, so an unaccepted license fails in seconds rather
  than after a partial pull:
  `curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $HF_TOKEN" https://huggingface.co/<repo>/resolve/main/config.json`
  — `307`/`200` means granted, `401`/`403` means the license is unaccepted.
- Do not assume a checkpoint is gated. Precheck unauthenticated first; several NVIDIA policy
  checkpoints are public and need no token at all, and assuming otherwise invents a blocker.
- A warm cache does not substitute for a token when the loader resolves the repo through the Hub
  API. `HF_HUB_OFFLINE=1` turns that into a hard failure rather than a cache hit.
- Distinguish "gated" from "does not exist". `401` unauthenticated together with `404`
  *authenticated* means the repository is absent, not gated; a genuinely gated repo returns
  metadata with `"gated": "auto"|"manual"` once authenticated. Confirm with
  `https://huggingface.co/api/models?author=<org>&search=<term>` to catch renames.

## A documented checkpoint may not be published yet

Upstream docs get written against artifacts that are not public yet, especially in early releases.
Isaac Lab Arena 0.2.1's evaluation guide documented
`hf download nvidia/Arena-Franka-Lift-Object-RL-Task` while that repository still 404'd with a
valid token; it was published a week later, after
[IsaacLab-Arena#904](https://github.com/isaac-sim/IsaacLab-Arena/issues/904) reported the gap.

So treat a missing artifact as a point-in-time fact, not a permanent one. Record the date you
checked, prefer a workaround that does not depend on it, and re-check before repeating the claim —
a note saying a checkpoint "does not exist" silently rots into misinformation. Searching the issue
tracker for the artifact name costs nothing and often finds either a fix or a rename.

Run the existence precheck *before* abandoning a working fallback. Killing a training run to switch
to a checkpoint that turns out not to exist wastes the run and leaves nothing to show. When a long
run is interrupted, what survives is decided by the framework's save interval — RSL-RL's
`agent.save_interval` defaults to 200 iterations — not by where you stopped, so check that interval
before relying on an early stop.

## Measure whether a model repo is gated; do not assume it from the family

Assuming a Hugging Face token is required, and building a whole credential-staging step around it,
wastes time when the artifact is already public. Measured 2026-08-04 with
`curl -o /dev/null -w '%{http_code}'` against `/resolve/main/config.json`, where 307/200 means
reachable and 401/403 means gated:

| repo | unauthenticated |
| --- | --- |
| `nvidia/Cosmos3-Nano-Policy-DROID` | 307 |
| `nvidia/GR00T-N1.7-DROID` | 307 |
| `Qwen/Qwen3-VL-2B-Instruct` | 307 |
| `nvidia/Cosmos-Reason2-2B` | **401** |

So the RoboLab policy checkpoints for both Cosmos 3 and GR00T are public, and only
`Cosmos-Reason2-2B` — GR00T N1.7's VLM backbone — is gated. `nvidia/Cosmos3-{Edge,Nano,Super}` and
`nvidia/Cosmos-Guardrail1` (`gated: auto`) are also reachable unauthenticated.

Run the one-line check yourself rather than trusting this table: gating is a point-in-time property
the publisher can change in either direction. Where a token *is* needed, see the token-handling note
above.

## Do not quote a benchmark from one episode

Policy servers are often non-deterministic — the Cosmos 3 RoboLab server logs
`deterministic_seed=False` — so a single episode cannot distinguish a real difference from
variance. One measured run failed a task outright while four parallel episodes of the same
configuration all succeeded.

Quote success rates from several episodes. In RoboLab, `--num-envs 4` costs little more wall-clock
than `--num-envs 1` because the simulator step dominates and parallel environments share it.

Read per-run figures from the structured output the tool writes (RoboLab's `timing` block in
`episode_results.jsonl`), not from log lines: the first inference includes compilation and is not
representative. Let the GPU warm up before timing anything, and benchmark with representative
input — synthetic all-zero frames are the cheapest case and understate real camera input.

## Clear the Isaac Sim entrypoint before documenting a local `docker run`

`nvcr.io/nvidia/isaac-sim` and `nvcr.io/nvidia/isaac-lab` set an `ENTRYPOINT`
(`/isaac-sim/runheadless.sh`), so a local `docker run <image> /run.sh "<command>"` **appends** the
whole pipeline to the Kit command line instead of executing it. Kit ignores the unknown arguments,
starts the streaming app, and idles forever — no error, no output from the intended command, and
`docker ps` shows a healthy container. One run sat like this for 19 minutes before the cause was
found.

Run:ai hides the problem, because `--command` maps to the Kubernetes `command:` field, which
overrides `ENTRYPOINT`. An image validated only on Run:ai can therefore ship local instructions
that silently do nothing.

Add `ENTRYPOINT []` and `CMD ["/bin/bash"]` to any Isaac-derived image whose guide documents a
local `docker run`; see `docker/isaac-lab-arena/Dockerfile_0_2_1` and
`docker/isaac-lab-mimic/Dockerfile_3_0_0_beta2_patch1`. To recognize it, check `ps` inside the
container: the intended command appears as trailing arguments of `/isaac-sim/kit/kit ... .kit`
rather than as its own process.

## Verify Nucleus asset paths against the image's asset generation

Isaac Lab resolves cloud assets against `persistent.isaac.asset_root.cloud` in
`apps/isaaclab.python.kit` — `.../Assets/Isaac/6.0` in Isaac Lab 3.0.0-beta2.patch1. The Python
constants `ISAAC_NUCLEUS_DIR` and `ISAACLAB_NUCLEUS_DIR` are derived from that file at import time,
so a Kit `--/persistent/...` override does not change them.

Asset layouts move between generations while the code keeps the old relative path. Isaac Lab
3.0.0-beta2.patch1 requests `Robots/FrankaEmika/panda_instanceable.usd`, which exists under `5.0`
and `5.1` but moved to `Robots/FrankaEmika/Legacy/` in `6.0`, so every environment spawning the
Franka from that path — all of the Mimic and SkillGen stacking tasks — aborts at scene construction
with `FileNotFoundError: USD file not found at path`. This reads like a network or permissions
problem and is not one.

Enumerate what the tasks actually request, then `HEAD`-check each path:

```bash
grep -rhoE "\{ISAACLAB_NUCLEUS_DIR\}/[A-Za-z0-9_./-]+|\{ISAAC_NUCLEUS_DIR\}/[A-Za-z0-9_./-]+" \
  <task directory> | sort -u
curl -sI -o /dev/null -w '%{http_code}\n' "<asset root>/<relative path>"
```

Compare `content-length` and `etag` between generations before repointing anything; a matching pair
means the asset only moved, so a `sed` in the Dockerfile is a safe fix rather than a version
downgrade. Fix every reference, not the first one found — in that release the stale path appears in
both `isaaclab_assets/robots/franka.py` and
`isaaclab_tasks/direct/franka_cabinet/franka_cabinet_env_cfg.py`, so patching only the shared robot
config still leaves a broken task.

## Validate an evaluation harness with a published checkpoint before trusting any number

A 0% closed-loop success rate is the same observation for "the model did not learn" and "the
serving path is wrong", and a healthy training-loss curve does not separate them. Run a
**published checkpoint for the same task** through the same harness first, and only trust the
harness once it reproduces that checkpoint's reported number.

Two rounds of evaluation on a custom policy were spent measuring a broken evaluation
configuration, not a policy. The reference run that exposed it cost one job and about an hour.

Gate offline before spending episodes: feed recorded dataset observations to the served policy
and compare the predicted action chunk against the recorded actions, normalized by each
dimension's spread in the data (`mean |err| / std`). Below ~0.6 means the policy is genuinely
predicting; above ~1.0 means it is no better than the dataset mean, which is a serving fault
rather than a training one. That check takes minutes and catches contract mismatches that cost
hundreds of episodes to find closed-loop.

Establish a floor as well. A trained policy's 0/30 only means something next to a random policy
and a hold-position policy that also score 0/30, and partial-credit counters — grasps, contacts —
separate "fails at the end" from "never starts": one random baseline grasped the object 12 times
in 30 episodes while never completing the task.

## Reproduce a published result with the published settings, including the exact model repo

When a guide states an expected success rate, treat every value in it as load-bearing.

- **Check the checkpoint's identity, not just its task.** Published finetunes of one task are
  often released as sibling repositories whose names differ only by a suffix, where one is
  trained in simulation only and the other mixes in real-robot episodes and trades simulation
  score for transfer. Serving the wrong sibling scored 5/10 where the documented one scored
  10/10 under otherwise identical settings. Copy the model path from the guide
  character-for-character.
- **Do not add flags the guide omits.** Client defaults are part of the published result — the
  episode count and the seed especially. Setting them silently changes what "the published
  number" means. Equally, a flag you add may be redundant rather than wrong: check the server's
  own defaults before assuming you must pass one.
- **Read the observation contract out of the checkpoint**, not out of the client's defaults.
  A checkpoint's `experiment_cfg/conf.yaml` names the camera keys, the state keys and the action
  horizon it expects. A key that does not match fails loudly; a key that matches but is
  **swapped** produces no error and a quietly worse score — an inverted camera map plus the
  client's default prompt cost 13 points against the same checkpoint.
- **Scrutinize a result above the published band as hard as one below it.** Confirm the success
  signal fired for the documented reason, and check whether you selected the benchmark's easiest
  variant: a guide quoting a range often quotes it for the randomized variant, not the fixed one.

Verify the *shape* of the result, not only the tally. Where success is a termination condition
and failure is a step-limit timeout, extract the step at which each episode ended. Every episode
ending well short of the cap is the success condition firing; uniform step-limit timeouts are a
broken serving path; episodes ending after a handful of steps are an environment fault. All three
report as a percentage and only the middle one is ambiguous from the percentage alone.
