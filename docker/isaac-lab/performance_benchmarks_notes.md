# Isaac Lab Performance Benchmark Notes

These notes contain reusable operational findings. Commands belong in the
[benchmark guide](./performance_benchmarks.md). Keep measurements, node names,
and artifact locations under the ignored `artifacts/` directory or in an
external run report.

## Version selection

Use `j3soon/runai-isaac-lab:2.2.0` for the full reference matrix. Resolve and
record its registry manifest digest with each external run report.

Do not use 2.3.2 for Camera benchmarking. In one-pod tests with two, three, and
four GPUs, every nonzero local rank failed during scene startup with:

```text
C++ UsdStage::SelectPrims: GPU 1 requested. GPUs other than cuda:0 are not currently supported
```

The failure reproduced on four L40 nodes and on the four-node topology, so it
is not node-specific. Upstream [issue #5562](https://github.com/isaac-sim/IsaacLab/issues/5562)
reports the same 2.3.2 Camera behavior. In the tagged source,
[`AppLauncher`](https://github.com/isaac-sim/IsaacLab/blob/v2.3.2/source/isaaclab/isaaclab/app/app_launcher.py#L626-L646)
and [`benchmark_rlgames.py`](https://github.com/isaac-sim/IsaacLab/blob/v2.3.2/scripts/benchmarks/benchmark_rlgames.py#L136-L159)
map each local rank to `cuda:<local_rank>` before the renderer rejects nonzero
devices.

Isaac Lab 2.2.0 completed ten Camera epochs with active processes on
`cuda:0-3`. A 2.1.0 diagnostic reached training on `cuda:3`, but other ranks
lost an extension-download race, so use 2.2.0 rather than 2.1.0. The tested
behavioral boundary is after 2.2.0 and by 2.3.2; these runs do not identify the
exact intervening commit.

Do not work around the 2.3.2 failure with `CUDA_VISIBLE_DEVICES`, four one-GPU
pods, or `--nproc_per_node=1`. Device masking breaks Omniverse device discovery,
and the other layouts no longer reproduce one four-GPU pod with four processes.

## Topology and scheduling

- A single-node run is one pod with four assigned L40s and four local processes.
- A 16-GPU run is four distinct nodes with one four-GPU pod per node.
- A distributed workload does not prove node separation. Save each pod's node
  and rank before measurement.
- Run:ai may bin-pack PyTorch pods. If one authorized pool cannot place four
  distinct nodes, use the guide's four-workload manual rendezvous across pools
  explicitly authorized by the user.
- `--required-pod-topology-key kubernetes.io/hostname` co-locates pods; it does
  not provide anti-affinity.
- Keep `--clean-pod-policy None` until every rank's logs and placement are saved.
- Gang-scheduling capacity messages are infrastructure exclusions, not
  benchmark failures.

When one node is a repeatable throughput outlier, preserve its run under
`diagnostics/`, state the exclusion reason, and repeat on a distinct healthy
node. Never silently replace or delete an outlier.

## Measurement integrity

- Stage reviewed runner logic on NFS and record its SHA-256. Avoid nested shell
  logic in `/run.sh` arguments.
- Write KPI JSON directly to NFS and verify it from a separate reader after the
  benchmark exits. Run:ai stdout is not durable evidence.
- Only global rank zero writes the final KPI. Use a shared output directory but
  a separate local working directory per pod.
- Run three scored repetitions. Treat missing KPI data, bad topology or
  metadata, and population CV above 5% as incomplete or inconclusive.
- Treat a stable median below 90% of the official value as a performance miss.
  Audit values above 120% for task, environment count, topology, and metric
  mapping. These tolerances are repository policy, not NVIDIA criteria.
- For G1, combine `benchmark_non_rl.py` environment-only FPS with RSL-RL
  collection and total FPS for inference and training.
- Do not profile or add `NCCL_SHM_DISABLE`, `NCCL_IB_DISABLE`, or `NCCL_ALGO`
  overrides during scored runs; they can change performance.

If distributed step/inference scales but training does not, investigate
policy-update and communication time in a separate unscored diagnostic. Do not
infer a communication root cause from aggregate FPS alone.

## Isaac Lab 3.0 compatibility

The `j3soon/runai-isaac-lab:3.0.0-beta2.patch1` wrapper completed Camera on the
required four-GPU pods. Resolve its current registry digest when using it.

Isaac Lab 3.0 uses `--benchmark_backend=omniperf --output_path=<DIR>` and writes
`benchmark_*.json`; 2.x uses the Kit metrics output-folder setting and writes
`kpis_*.json`. Metadata also moved into `benchmark_info` and
`hardware_info.gpu_devices`. The repository runner and verifier support both.
Run the 3.0 RL-Games benchmark from `/workspace/isaaclab` because it imports
`scripts.benchmarks`.
