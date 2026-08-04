#!/bin/bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <single-node|pytorch|manual> <task> <output-dir>" >&2
  exit 64
fi

topology=$1
task=$2
output_dir=$3
benchmark_version=${ISAACLAB_BENCHMARK_VERSION:-2.2.0}

if [[ ! "${benchmark_version}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Invalid ISAACLAB_BENCHMARK_VERSION: ${benchmark_version}" >&2
  exit 64
fi

if [[ "${benchmark_version}" == 2.* ]]; then
  rlgames_output_args=(
    --kit_args="--/exts/isaacsim.benchmark.services/metrics/metrics_output_folder=${output_dir}/rlgames"
  )
  nonrl_output_args=(
    --kit_args="--/exts/isaacsim.benchmark.services/metrics/metrics_output_folder=${output_dir}/nonrl"
  )
  rsl_output_args=(
    --kit_args="--/exts/isaacsim.benchmark.services/metrics/metrics_output_folder=${output_dir}/rsl"
  )
else
  rlgames_output_args=(--benchmark_backend=omniperf --output_path="${output_dir}/rlgames")
  nonrl_output_args=(--benchmark_backend=omniperf --output_path="${output_dir}/nonrl")
  rsl_output_args=(--benchmark_backend=omniperf --output_path="${output_dir}/rsl")
fi

case "${task}" in
  Isaac-Cartpole-Direct-v0)
    num_envs=4096
    short_name=cartpole
    workflow=rlgames
    app_args=()
    ;;
  Isaac-Cartpole-RGB-Camera-Direct-v0)
    num_envs=1024
    short_name=camera
    workflow=rlgames
    app_args=(--enable_cameras)
    ;;
  Isaac-Velocity-Rough-G1-v0)
    num_envs=4096
    short_name=g1
    workflow=rsl
    app_args=()
    ;;
  Isaac-Repose-Cube-Shadow-Direct-v0)
    num_envs=8192
    short_name=repose
    workflow=rlgames
    app_args=()
    ;;
  *)
    echo "Unsupported task: ${task}" >&2
    exit 64
    ;;
esac

case "${topology}" in
  single-node)
    torchrun_args=(--nnodes=1 --nproc_per_node=4)
    ;;
  pytorch)
    torchrun_args=()
    echo "Waiting 60 seconds for the PyTorch workload topology gate..."
    sleep 60
    ;;
  manual)
    : "${BENCH_NODE_RANK:?set BENCH_NODE_RANK}"
    : "${BENCH_COORD_DIR:?set BENCH_COORD_DIR}"
    mkdir -p "${BENCH_COORD_DIR}"
    if [[ "${BENCH_NODE_RANK}" == 0 ]]; then
      hostname -i | awk '{print $1}' > "${BENCH_COORD_DIR}/master_addr.tmp"
      mv "${BENCH_COORD_DIR}/master_addr.tmp" "${BENCH_COORD_DIR}/master_addr"
    fi
    for _ in {1..120}; do
      [[ -s "${BENCH_COORD_DIR}/master_addr" ]] && break
      sleep 1
    done
    [[ -s "${BENCH_COORD_DIR}/master_addr" ]] || {
      echo "Timed out waiting for the manual rendezvous address" >&2
      exit 1
    }
    master_addr=$(<"${BENCH_COORD_DIR}/master_addr")
    torchrun_args=(
      --nnodes=4
      --nproc_per_node=4
      --node_rank="${BENCH_NODE_RANK}"
      --master_addr="${master_addr}"
      --master_port="${BENCH_MASTER_PORT:-29500}"
    )
    echo "Waiting 60 seconds for the manual four-node topology gate..."
    sleep 60
    ;;
  *)
    echo "Unsupported topology: ${topology}" >&2
    exit 64
    ;;
esac

mkdir -p "${output_dir}"
work_dir="/tmp/isaaclab-${benchmark_version}-${short_name}-${HOSTNAME}"
mkdir -p "${work_dir}"
if [[ "${benchmark_version}" == 2.* ]]; then
  cd "${work_dir}"
else
  cd /workspace/isaaclab
fi
nvidia-smi -q -f "${output_dir}/nvidia-smi-q-${HOSTNAME}.txt"
log_file="${output_dir}/benchmark-${HOSTNAME}.log"

run_logged() {
  "$@" 2>&1 | tee -a "${log_file}"
}

if [[ "${workflow}" == rlgames ]]; then
  mkdir -p "${output_dir}/rlgames"
  run_logged /workspace/isaaclab/isaaclab.sh -p -u -m torch.distributed.run \
    "${torchrun_args[@]}" \
    /workspace/isaaclab/scripts/benchmarks/benchmark_rlgames.py \
    --task="${task}" \
    --num_envs="${num_envs}" \
    --max_iterations=10 \
    --headless \
    "${app_args[@]}" \
    --distributed \
    "${rlgames_output_args[@]}"
else
  mkdir -p "${output_dir}/nonrl" "${output_dir}/rsl"
  run_logged /workspace/isaaclab/isaaclab.sh -p -u -m torch.distributed.run \
    "${torchrun_args[@]}" \
    /workspace/isaaclab/scripts/benchmarks/benchmark_non_rl.py \
    --task="${task}" \
    --num_envs="${num_envs}" \
    --num_frames=100 \
    --headless \
    --distributed \
    "${nonrl_output_args[@]}"
  run_logged /workspace/isaaclab/isaaclab.sh -p -u -m torch.distributed.run \
    "${torchrun_args[@]}" \
    /workspace/isaaclab/scripts/benchmarks/benchmark_rsl_rl.py \
    --task="${task}" \
    --num_envs="${num_envs}" \
    --max_iterations=10 \
    --headless \
    --distributed \
    "${rsl_output_args[@]}"
fi
