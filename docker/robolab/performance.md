# RoboLab Performance

Measurements for [`j3soon/runai-robolab:0.3.0`](./README.md), taken 2026-08-11.

Numbers are hardware- and build-specific. Treat them as a reference point for what "working" looks
like, not as targets. Re-measure on your own node before drawing conclusions.

- GPU: NVIDIA RTX PRO 6000 Blackwell Max-Q (97887 MiB), driver 580.173.02
- Image: 38.5GB in `docker images`, 13GB from `docker image inspect`; baked assets 5.8GB
- Task: `BananaInBowlTask`, policy server and simulator client sharing one GPU over `--net host`
- Figures from the `timing` block RoboLab writes into `episode_results.jsonl`

## Throughput by backend

| | Cosmos 3 Nano | GR00T N1.7 |
| --- | --- | --- |
| Policy inference | 91.5 ms/step | 15.6 ms/step |
| Simulator step | 179.1 ms/step | 173.9 ms/step |
| Throughput | 3.62 it/s | 5.15 it/s |
| Result | 4/4 success, 167-188 steps | success, 106 steps |

The simulator, not the policy, is the bottleneck in both cases, so upstream's ~200ms inference
budget holds comfortably. GR00T's per-step figure benefits from `--open-loop-horizon 8`, which
reuses each 40-step action chunk across 8 environment steps. See
[`docker/isaac-gr00t-n1.7/performance.md`](../isaac-gr00t-n1.7/performance.md) for that server's
standalone latency.

## Run-to-run variance

The Cosmos 3 policy server logs `deterministic_seed=False` at startup, so episodes are not
reproducible. In one measured run a single-env episode failed outright — 750 steps without a grasp,
`ee_path_length` 4.63 — while four parallel episodes of the same configuration all succeeded, at
167-188 steps with `ee_path_length` 0.97-1.05.

Consequences for anyone benchmarking here:

- **Quote success rates from several episodes, never one.** A 1-vs-1 comparison across image
  versions cannot distinguish a regression from variance.
- **Prefer `--num-envs 4` for any success-rate claim.** It costs little more wall-clock than
  `--num-envs 1`, because the simulator step dominates and parallel environments share it.
- **Do not estimate throughput from the first sampling line in the server log.** The first
  inference includes compilation, about 9s for Cosmos 3, and is not representative. Read the
  `timing` block instead.

## Resource footprint

Server and client together used 49.5GB of VRAM for Cosmos 3, above the 46GB of a `prod` L40, so
that pair does not co-locate on one such node. GR00T's server is far smaller at about 7GB, so that
pair fits comfortably.

## Cross-version comparability

RoboLab v0.3.0 changed the coordinate-frame contract: end-effector observations moved to the
robot-root frame. Scores are not comparable across the v0.2.x / v0.3.x boundary in either
direction. The figures above are v0.3.0 measurements throughout.

Isaac Sim 5.0 and 5.1 also ship different PhysX builds, so results are not comparable across the
`isaac50` / `isaac51` stacks either.
