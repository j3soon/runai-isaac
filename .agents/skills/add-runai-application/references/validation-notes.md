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
