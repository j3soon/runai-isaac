# Isaac Lab Arena Performance

Measurements for [`j3soon/runai-isaac-lab-arena:0.2.1`](./README.md), taken 2026-08-04.

Numbers are hardware- and build-specific. Treat them as a reference point for what "working"
looks like, not as targets. Re-measure on your own node before drawing conclusions.

- GPU: NVIDIA RTX PRO 6000 Blackwell Max-Q (97887 MiB), driver 580.173.02, 48 threads / 47 GiB
- Image: 14.6GB, built from `Dockerfile_0_2_1` in 31 steps
- Base: `nvcr.io/nvidia/isaac-sim:6.0.0-dev2`, Arena pinned at `8b4a3a4` (`release/0.2.1`)

## Startup

Startup downloads Isaac Sim assets and compiles shaders before the first rollout step. Look for
`[isaaclab-arena] AppLauncher initialization complete` to confirm the simulator came up, then
`Starting rollout`.

| Configuration | Time to environment ready |
| --- | --- |
| Headless, no cameras | about 25s |
| `--enable_cameras`, cold shader cache | about 3.5 minutes (215s) |
| `--enable_cameras`, warm shader cache | about 30s |

The shader cache is what changes between the last two rows, so mounting it (see the guide's local
run block) is worth it for repeated camera-enabled runs. It reached 292MB on the host after one
camera-enabled run.

## Evaluation

`zero_action` over 20 steps, the plumbing check:

```
{'success_rate': 0.0, 'object_moved_rate': nan, 'num_episodes': 0}
```

Zeros here are correct, not a silent skip: the policy issues no actions and 20 steps is shorter
than one episode, so nothing terminates and no success can be recorded.

`rsl_rl` on `lift_object` with a locally trained checkpoint, 2 episodes:

| Checkpoint | Result |
| --- | --- |
| `model_400.pt` (400 iterations) | `{'success_rate': 0.5, 'num_episodes': 2}` |

The arm grasps the cube and lifts it to the goal marker on one of two attempts. Train the full
2000 iterations for a policy that succeeds consistently.

## RSL-RL training

Isaac Lab's RSL-RL script with the Arena registration callback, `lift_object`, 4096 environments:

| Metric | Value |
| --- | --- |
| Startup to first iteration | about 70s |
| Per iteration | about 0.8s (first iteration 2.2s) |
| Full 2000-iteration recipe | roughly 27 minutes plus startup |
| Checkpoint interval | `agent.save_interval`, default 200 iterations |

Mean reward progression on `lift_object`: 0.72 at iteration 0, 5.02 at 77, 27.14 at 111, 75.00 at
158, 99.02 at 552.

## Video recording

Recording forces a render per step and is much slower than headless evaluation. Use it for spot
checks, not for evaluation sweeps.

| Run | Output |
| --- | --- |
| `zero_action`, 60 steps, `--enable_cameras --viz kit` | 60 frames, 1280x720, about 67KB |
| `rsl_rl`, 2 episodes, same flags | 320 frames, 1280x720, about 810KB |

File size is the cheap correctness check. A blank 20-frame 720p clip is about 3KB because it
encodes an empty viewport; a real scene is hundreds of KB. See the `--viz kit` note in the guide
for why an empty recording is produced in the first place.

The `rsl_rl` clip is 320 frames rather than the 500 announced by `Recording 500-step video`:
`RecordVideo` budgets `num_episodes * max_episode_length` but stops when the episodes actually end.
