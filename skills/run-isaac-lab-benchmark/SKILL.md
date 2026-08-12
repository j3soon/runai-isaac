---
name: run-isaac-lab-benchmark
description: Reproduce, compare, diagnose, and verify the Isaac Lab L40 reinforcement-learning performance benchmark on NVIDIA Run:ai. Use for the repository's single-node 4-GPU or four-node 16-GPU Isaac Lab benchmark, version comparisons, Camera compatibility checks, KPI validation, topology auditing, or benchmark result documentation.
---

# Run Isaac Lab Benchmark

Use the repository runner and verifier to produce repeatable L40 measurements with durable evidence. Read `docker/isaac-lab/performance_benchmarks.md` before submitting. Also use the `launch-runai-workload` skill for Run:ai preflight, storage, submission, monitoring, and cleanup rules.

## Select the version

- Default to the documented Isaac Lab 2.2.0 image for the full matrix. It has been validated with Camera processes on `cuda:0-3`.
- Do not use 2.3.2 for a full Camera reproduction. The tested image rejects nonzero local render devices with `GPUs other than cuda:0 are not currently supported`; upstream issue [#5562](https://github.com/isaac-sim/IsaacLab/issues/5562) reports the same 2.3.2 behavior.
- Use 2.3.2 only for non-Camera comparisons or an explicit regression reproduction. Mark its Camera cells incomplete.
- Treat 3.0.0 beta2 patch1 as a compatibility comparison, not the 2.2.0 reference environment. Its KPI schema and benchmark output arguments differ; the repository scripts handle both.
- Resolve and record the registry manifest digest even though repository Dockerfile `FROM` lines use version tags without digests.

## Establish the evidence contract

1. Record the image tag and digest, project, authorized pool, NFS mapping, runner and verifier hashes, driver, GPU, CPU, OS, task settings, and unique UTC run ID.
2. Put all logs, KPI JSON, GPU inventories, topology records, hashes, and verifier output below one NFS run root.
3. Run one unscored functional/topology qualification, followed by three scored repetitions per matrix cell.
4. Keep scored runs unchanged: do not profile, mask GPUs, or add NCCL transport overrides. Submit them non-preemptible, and record the setting with the run metadata. A reclaimed pod truncates a repetition mid-measurement, and a partial KPI file is not obviously distinguishable from a complete one.
5. Preserve every excluded run under `diagnostics/` with its original evidence and a written exclusion reason. Never silently replace an outlier.

## Preserve the benchmark topology

- Single node: submit one pod with four L40s and use four local processes. Do not substitute four one-GPU pods or `--nproc_per_node=1`.
- Multi-node: use four distinct physical nodes, one pod with four L40s per node, and 16 total processes.
- Let the Run:ai PyTorch operator supply rank and rendezvous values when it places four distinct nodes.
- If it bin-packs pods or one pool lacks capacity, use the guide's manual four-workload mode only across pools the user explicitly authorized.
- Use the runner's topology gate to inspect every pod before measurement. Stop and exclude a mismatched repetition.

## Execute and monitor

1. Stage `scripts/isaac_lab/run_performance_benchmark.sh` on NFS and verify its SHA-256.
2. Submit the exact commands from the guide with an explicit project, pool, image-pull policy, four GPUs per pod, large shared memory, zero retries, and the confirmed NFS mount.
3. Capture logs and GPU inventory from every rank. Distinguish scheduling, image-pull, rendezvous, renderer, and benchmark failures.
4. Keep completed workloads until a separate reader has verified the NFS artifacts, then delete only workloads created for the run.

## Verify and report

Run `scripts/isaac_lab/verify_performance_benchmarks.py <run-root>` from an independent reader. Require:

- the requested node/process topology;
- three readable KPI measurements for every metric and cell;
- correct task, environment count, iteration/frame count, and L40 metadata;
- median FPS at least 90% of the official target;
- population CV at most 5%.

Treat verifier exit `0` as a successful full reproduction, `1` as stable performance degradation, and `2` as incomplete or inconclusive evidence. Values above 120% pass but require a metadata/topology audit. Report measured and official triplets as step / inference / training FPS, percentage deltas, variability, exclusions, and the durable artifact path. Store the result report under the ignored `artifacts/` directory or outside the repository; keep only reusable operational findings in `docker/isaac-lab/performance_benchmarks_notes.md`.
