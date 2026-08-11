# Isaac GR00T N1.7 Performance

Measurements for [`j3soon/runai-isaac-gr00t:n1.7`](./README.md), taken 2026-08-06.

Numbers are hardware- and build-specific. Treat them as a reference point for what "working"
looks like, not as targets. Re-measure on your own node before drawing conclusions.

- GPU: NVIDIA RTX PRO 6000 Blackwell Max-Q (97887 MiB), driver 580.173.02
- Image: 14.7GB in `docker images`, 14GB from `docker image inspect`
- Checkpoint: `nvidia/GR00T-N1.7-DROID` with the gated `nvidia/Cosmos-Reason2-2B` backbone
- Server VRAM: about 7GB resident

## Standalone inference latency

A native `PolicyClient` round trip against the DROID embodiment, driven by a synthetic observation
built from the server's own modality config, so no dataset is required. Latency varies with
observation image content:

| Observation images | Mean | Min | Max |
| --- | --- | --- | --- |
| All zeros | 68-74ms | 61.7ms | 109.2ms |
| Gradient | 81.5ms | 65.0ms | 119.5ms |
| Random noise | 106.3ms | 69.3ms | 164.2ms |

Two caveats before quoting any of these:

- **Let the GPU warm up.** The first calls after the server reports ready are several times slower
  while clocks ramp from idle. Measured immediately after startup, random-noise calls averaged
  266ms with an 825ms first call; the same workload settled to 106ms once warm. Discard at least
  the first ten calls.
- **Image content changes the cost.** Synthetic all-zero frames are the cheapest case and
  understate real camera input by roughly 40%. Benchmark with representative frames rather than
  `np.zeros`.

## In the RoboLab closed loop

Driving [RoboLab](../robolab/README.md)'s GR00T client against this server, `BananaInBowlTask`
succeeded with score 1.0 at episode step 106 on RoboLab v0.3.0 (step 175 on v0.2.1, before the
v0.3.0 coordinate-frame change; the two are not comparable). RoboLab's `timing` block reported:

| metric | value |
| --- | --- |
| `policy_inference_avg_ms` | 15.6 |
| `env_step_avg_ms` | 173.9 |
| `it_per_sec` | 5.15 |

The simulator step, not policy inference, dominates. The per-step inference figure is far below the
standalone latency above because `--open-loop-horizon 8` reuses each 40-step action chunk across 8
environment steps.

See [`docker/robolab/performance.md`](../robolab/performance.md) for the RoboLab side, including
the Cosmos 3 comparison and the variance caveat that applies to any success-rate claim.
