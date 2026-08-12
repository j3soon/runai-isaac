#!/bin/bash

set -u

image=""
host_dir=""
container_dir=""
gpu_mode="auto"
smoke_command=""

usage() {
  cat <<'EOF'
Usage: validate-local-mount.sh --image IMAGE --host-dir PATH --container-dir PATH [options]

Options:
  --gpu auto|required|disabled  GPU use policy (default: auto).
  --command COMMAND             Optional bounded command to run after the probe.
  -h, --help                    Show this help.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --image)
      (($# >= 2)) || die "--image requires a value"
      image=$2
      shift 2
      ;;
    --host-dir)
      (($# >= 2)) || die "--host-dir requires a value"
      host_dir=$2
      shift 2
      ;;
    --container-dir)
      (($# >= 2)) || die "--container-dir requires a value"
      container_dir=$2
      shift 2
      ;;
    --gpu)
      (($# >= 2)) || die "--gpu requires a value"
      gpu_mode=$2
      shift 2
      ;;
    --command)
      (($# >= 2)) || die "--command requires a value"
      smoke_command=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

[[ -n "$image" ]] || die "--image is required"
[[ -n "$host_dir" ]] || die "--host-dir is required"
[[ -n "$container_dir" ]] || die "--container-dir is required"
[[ "$host_dir" = /* ]] || die "--host-dir must be an absolute path"
[[ "$container_dir" = /* ]] || die "--container-dir must be an absolute path"
[[ -d "$host_dir" ]] || die "host directory does not exist: $host_dir"
[[ -w "$host_dir" ]] || die "host directory is not writable: $host_dir"
case "$gpu_mode" in
  auto|required|disabled) ;;
  *) die "--gpu must be auto, required, or disabled" ;;
esac

command -v docker >/dev/null 2>&1 || die "docker is not installed"
docker info >/dev/null 2>&1 || die "docker cannot reach the daemon"

use_gpu=0
if [[ "$gpu_mode" != "disabled" ]] \
    && command -v nvidia-smi >/dev/null 2>&1 \
    && nvidia-smi -L >/dev/null 2>&1 \
    && docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"nvidia"'; then
  use_gpu=1
elif [[ "$gpu_mode" == "required" ]]; then
  die "a working host GPU and Docker NVIDIA runtime are required"
fi

marker_name=".runai-mount-probe.$$.${RANDOM}"
host_marker="$host_dir/$marker_name"
container_marker="$container_dir/$marker_name"

cleanup() {
  rm -f -- "$host_marker"
}
trap cleanup EXIT

docker_args=(run --rm --entrypoint /bin/sh --volume "$host_dir:$container_dir")
if ((use_gpu)); then
  docker_args+=(--gpus all)
fi
docker_args+=("$image" -lc '
set -eu
marker=$1
smoke=$2
printf "%s\n" "runai-local-mount-ok" > "$marker"
sync
test -s "$marker"
if [ -n "$smoke" ]; then
  /bin/sh -lc "$smoke"
fi
' sh "$container_marker" "$smoke_command")

printf 'Running image %s with %s at %s\n' "$image" \
  "$([[ $use_gpu -eq 1 ]] && printf 'GPU enabled' || printf 'GPU disabled')" \
  "$container_dir"
if ! docker "${docker_args[@]}"; then
  die "container command failed"
fi

[[ -s "$host_marker" ]] || die "probe was not visible on the host after container exit"
grep -qx 'runai-local-mount-ok' "$host_marker" \
  || die "probe contents changed across the bind mount"

printf 'PASS: container write persisted to host path %s\n' "$host_marker"
