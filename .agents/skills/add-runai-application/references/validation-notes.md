# Validation Notes

Pitfalls found while building and validating Docker-backed applications in this repository. Each
one produced a wrong conclusion at least once, so check against it before reporting a result.

## Capture simulator video in-app, not by screen capture

`ffmpeg -f x11grab` records solid black for an Isaac Sim window, even when the GUI is mapped and
rendering correctly.

Isaac Sim presents its viewport through a Vulkan swapchain, while `x11grab` reads via `XGetImage`
on the root window, which cannot see that surface under a compositing desktop. `xwd -root` is black
for the same reason, so this is not a window-geometry or offset mistake.

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

## A documented checkpoint may never have been published

Upstream docs advertise pre-trained artifacts that do not exist, especially in early releases.
Isaac Lab Arena 0.2.1's evaluation guide documents
`hf download nvidia/Arena-Franka-Lift-Object-RL-Task`; that repository 404s even with a valid
token, so training locally is the only route to that checkpoint.

Run the existence precheck *before* abandoning a working fallback. Killing a training run to switch
to a checkpoint that turns out not to exist wastes the run and leaves nothing to show. When a long
run is interrupted, what survives is decided by the framework's save interval — RSL-RL's
`agent.save_interval` defaults to 200 iterations — not by where you stopped, so check that interval
before relying on an early stop.

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
