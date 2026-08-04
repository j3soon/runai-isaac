# Isaac Lab Performance Benchmarks

This guide reproduces the Isaac Lab 2.2.0 [performance benchmarks](https://isaac-sim.github.io/IsaacLab/v2.2.0/source/overview/reinforcement-learning/performance_benchmarks.html). Use finite training workloads, run each case three times, and save KPI files on NFS.

Use 2.2.0 for the full matrix. The tested 2.3.2 image rejects Camera rendering
on nonzero local GPU ranks; upstream [issue #5562](https://github.com/isaac-sim/IsaacLab/issues/5562)
reports the same error. Use 2.3.2 only to reproduce that regression or for
non-Camera comparisons.

## Benchmark matrix

| Task | Short name | Runner | Environments per GPU | 4 x L40 target FPS | 16 x L40 target FPS |
|---|---|---|---:|---:|---:|
| `Isaac-Cartpole-Direct-v0` | `cartpole` | RL-Games | 4096 | 2.70M / 2.10M / 0.95M | 10.2M / 8.2M / 3.5M |
| `Isaac-Cartpole-RGB-Camera-Direct-v0` | `camera` | RL-Games | 1024 | 130K / 120K / 90K | 530K / 490K / 260K |
| `Isaac-Velocity-Rough-G1-v0` | `g1` | RSL-RL | 4096 | 290K / 270K / 250K | 1.20M / 1.10M / 960K |
| `Isaac-Repose-Cube-Shadow-Direct-v0` | `repose` | RL-Games | 8192 | 440K / 420K / 390K | 2.40M / 2.30M / 1.80M |

The three values are environment step, step plus inference, and step plus inference plus training FPS.

## Configure the run

```sh
export SSL_CERT_FILE="${HOME}/.runai/certs/root-ca.crt"

BENCH_PROJECT=<RUNAI_PROJECT>
BENCH_USER=<RUNAI_USERNAME>
BENCH_NFS_SERVER=<NFS_SERVER>
BENCH_NFS_PATH=<NFS_EXPORT>
BENCH_POOL=<RUNAI_NODE_POOL>
BENCH_VERSION=2.2.0
BENCH_IMAGE=j3soon/runai-isaac-lab:2.2.0
BENCH_RUN_ID=$(date -u +%Y%m%dt%H%M%Sz)
BENCH_ROOT=/mnt/nfs/${BENCH_USER}/isaaclab-benchmarks/${BENCH_VERSION}/${BENCH_RUN_ID}
BENCH_RUNNER=${BENCH_ROOT}/launch/run_performance_benchmark.sh
```

Resolve the NFS mapping from the approved Run:ai data source. Do not guess it from the data-source name.
Use another pool only when its owner has authorized benchmark workloads there.
Resolve and record the image's registry manifest digest with the external run
evidence; do not embed a validation-time digest in this guide.

For a 2.3.2 regression comparison, select its image. Its official L40 targets
are identical to the matrix above.

```sh
BENCH_VERSION=2.3.2
BENCH_IMAGE=j3soon/runai-isaac-lab:2.3.2
```

For the 3.0.0 beta2 patch1 retry, use the published wrapper pinned to its registry manifest:

```sh
BENCH_VERSION=3.0.0-beta2.patch1
BENCH_IMAGE=j3soon/runai-isaac-lab:3.0.0-beta2.patch1
```

After selecting another version, recalculate `BENCH_ROOT` and `BENCH_RUNNER`.
Keep the targets above so every run remains directly comparable.

In a shell with this repository and NFS mounted, copy [`run_performance_benchmark.sh`](../../scripts/isaac_lab/run_performance_benchmark.sh) to `BENCH_RUNNER`, make it executable, and record its hash. Otherwise use the approved NFS file-transfer path.

```sh
mkdir -p "$(dirname "${BENCH_RUNNER}")"
install -m 0755 scripts/isaac_lab/run_performance_benchmark.sh "${BENCH_RUNNER}"
sha256sum "${BENCH_RUNNER}"
```

## Single node, 4 x L40

Set one task and repetition:

```sh
BENCH_TASK=Isaac-Cartpole-Direct-v0
BENCH_SHORT=cartpole
BENCH_REP=r1
BENCH_OUT=${BENCH_ROOT}/single-node-4gpu/${BENCH_SHORT}/${BENCH_REP}
BENCH_NAME=${BENCH_USER}-ilbench-s4-${BENCH_SHORT}-${BENCH_REP}
```

Submit one four-GPU pod:

```sh
runai training standard submit "${BENCH_NAME}" \
  --project "${BENCH_PROJECT}" \
  --image "${BENCH_IMAGE}" \
  --image-pull-policy Always \
  --node-pools "${BENCH_POOL}" \
  --gpu-devices-request 4 \
  --large-shm \
  --nfs "server=${BENCH_NFS_SERVER},path=${BENCH_NFS_PATH},mountpath=/mnt/nfs,readwrite" \
  --backoff-limit 0 \
  --restart-policy Never \
  --user-group-source fromTheImage \
  --environment "ISAACLAB_BENCHMARK_VERSION=${BENCH_VERSION}" \
  --command -- "${BENCH_RUNNER}" single-node "${BENCH_TASK}" "${BENCH_OUT}"
```

Wait for `Completed`, then repeat with `BENCH_REP=r2` and `r3`, recalculating `BENCH_OUT` and `BENCH_NAME` each time. Change the task and short name using the matrix. The runner executes both the non-RL and RSL-RL measurements required for G1.

Use the same single-pod, four-GPU command for the Camera task. Four one-GPU pods change the process, IPC, and GPU communication topology and are not an equivalent benchmark. The tested 2.2.0 image completed Camera on `cuda:0-3`.

## Four nodes, 16 x L40

The Run:ai PyTorch operator supplies rank, node count, and rendezvous settings to the same runner.

```sh
BENCH_OUT=${BENCH_ROOT}/multi-node-16gpu/${BENCH_SHORT}/${BENCH_REP}
BENCH_NAME=${BENCH_USER}-ilbench-m16-${BENCH_SHORT}-${BENCH_REP}

runai training pytorch submit "${BENCH_NAME}" \
  --project "${BENCH_PROJECT}" \
  --image "${BENCH_IMAGE}" \
  --image-pull-policy Always \
  --node-pools "${BENCH_POOL}" \
  --workers 3 \
  --gpu-devices-request 4 \
  --master-gpu-devices-request 4 \
  --large-shm \
  --nfs "server=${BENCH_NFS_SERVER},path=${BENCH_NFS_PATH},mountpath=/mnt/nfs,readwrite" \
  --backoff-limit 0 \
  --restart-policy Never \
  --master-restart-policy Never \
  --clean-pod-policy None \
  --user-group-source fromTheImage \
  --environment "ISAACLAB_BENCHMARK_VERSION=${BENCH_VERSION}" \
  --master-command "/run.sh \"${BENCH_RUNNER} pytorch ${BENCH_TASK} ${BENCH_OUT}\"" \
  --command -- /run.sh "${BENCH_RUNNER} pytorch ${BENCH_TASK} ${BENCH_OUT}"
```

The runner waits 60 seconds before measuring. During that gate, use `runai training pytorch describe` and require four pods on four distinct nodes, each with four L40s. Stop the workload if the topology differs, and collect logs from every pod.

If the operator bin-packs pods or one pool lacks four nodes, submit four standard
workloads with a shared rendezvous directory. Set a unique rank `0-3`, select an
authorized pool for each rank, and submit all ranks promptly:

```sh
BENCH_NODE_RANK=0
BENCH_RANK_POOL=<RUNAI_NODE_POOL>
BENCH_COORD=${BENCH_ROOT}/coord/${BENCH_SHORT}-${BENCH_REP}

runai training standard submit "${BENCH_NAME}-n${BENCH_NODE_RANK}" \
  --project "${BENCH_PROJECT}" \
  --image "${BENCH_IMAGE}" \
  --image-pull-policy Always \
  --node-pools "${BENCH_RANK_POOL}" \
  --gpu-devices-request 4 \
  --large-shm \
  --nfs "server=${BENCH_NFS_SERVER},path=${BENCH_NFS_PATH},mountpath=/mnt/nfs,readwrite" \
  --backoff-limit 0 \
  --restart-policy Never \
  --user-group-source fromTheImage \
  --environment "ISAACLAB_BENCHMARK_VERSION=${BENCH_VERSION}" \
  --environment "BENCH_NODE_RANK=${BENCH_NODE_RANK}" \
  --environment "BENCH_COORD_DIR=${BENCH_COORD}" \
  --command -- "${BENCH_RUNNER}" manual "${BENCH_TASK}" "${BENCH_OUT}"
```

Require four distinct nodes during the same topology gate. This fallback is not
gang-scheduled; if any rank fails or is preempted, stop all four and exclude the
repetition.

The 2.3.2 Camera task fails on tested local ranks 1-3 because its renderer
supports only `cuda:0`. Mark that cell incomplete. Sixteen one-GPU pods avoid
the error but change the distributed process topology and are not an equivalent
reproduction. The tested 2.2.0 and 3.0 images completed Camera with four-GPU pods.

## Verify

From a separate shell or reader workload, confirm every repetition produced a non-empty KPI JSON, then run:

```sh
python3 scripts/isaac_lab/verify_performance_benchmarks.py "${BENCH_ROOT}"
```

A successful full reproduction has the exact requested topology, three readable KPI files for every matrix cell, every median at least 90% of its upstream target, population CV at most 5%, and verifier exit code `0`. Exit code `1` means valid measurements missed a performance threshold. Exit code `2`, a mismatched topology, failed workload, missing KPI, bad metadata, or CV above 5% means incomplete or inconclusive evidence, not a performance failure.

The CLI examples invoke the staged runner directly. In a Run:ai environment-command field, use `/run.sh "${BENCH_RUNNER} ..."`; keep non-trivial logic in the reviewed runner file.

See [operational notes](./performance_benchmarks_notes.md) for topology, Camera,
KPI, and troubleshooting findings. Store cluster-specific measurements under
the ignored `artifacts/` directory or outside this repository.
