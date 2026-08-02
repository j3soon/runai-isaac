#!/bin/bash

set -u

project=""
local_output_dir=""
require_docker=0
require_gpu=0
passes=0
warnings=0
failures=0

usage() {
  cat <<'EOF'
Usage: preflight.sh [options]

Options:
  --project NAME            Require access to this Run:ai project.
  --local-output-dir PATH   Check a local directory for mount simulation.
  --require-docker          Fail instead of warn when Docker is unavailable.
  --require-gpu             Fail instead of warn when local GPU support is unavailable.
  -h, --help                Show this help.
EOF
}

pass() {
  printf 'PASS: %s\n' "$*"
  passes=$((passes + 1))
}

warn() {
  printf 'WARN: %s\n' "$*"
  warnings=$((warnings + 1))
}

fail() {
  printf 'FAIL: %s\n' "$*"
  failures=$((failures + 1))
}

while (($#)); do
  case "$1" in
    --project)
      if (($# < 2)); then
        fail "--project requires a value"
        usage
        exit 2
      fi
      project=$2
      shift 2
      ;;
    --local-output-dir)
      if (($# < 2)); then
        fail "--local-output-dir requires a value"
        usage
        exit 2
      fi
      local_output_dir=$2
      shift 2
      ;;
    --require-docker)
      require_docker=1
      shift
      ;;
    --require-gpu)
      require_gpu=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      usage
      exit 2
      ;;
  esac
done

if command -v runai >/dev/null 2>&1; then
  runai_version=$(runai version 2>&1)
  pass "Run:ai CLI found (${runai_version//$'\n'/, })"

  if config_json=$(runai config describe --json 2>/dev/null); then
    if command -v python3 >/dev/null 2>&1; then
      context=$(printf '%s' "$config_json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
cluster = data.get("cluster", {})
project = cluster.get("project", {})
print("cluster={}, project={}".format(cluster.get("name", "?"), project.get("name", "?")))
' 2>/dev/null || true)
      if [[ -n "$context" ]]; then
        pass "Run:ai context readable ($context)"
      else
        warn "Run:ai context is present but could not be summarized"
      fi
    else
      pass "Run:ai context is readable"
    fi
  else
    fail "Run:ai context is not readable; configure the cluster first"
  fi

  if [[ -z "${SSL_CERT_FILE:-}" && -s "${HOME}/.runai/certs/root-ca.crt" ]]; then
    export SSL_CERT_FILE="${HOME}/.runai/certs/root-ca.crt"
    pass "Using the installed Run:ai root CA for this preflight"
  fi

  if identity=$(runai whoami 2>&1); then
    pass "Run:ai authentication is valid ($identity)"
  else
    fail "Run:ai authentication failed: ${identity//$'\n'/, }"
  fi

  if projects=$(runai project list --no-pagination 2>&1); then
    pass "Run:ai project list is accessible"
    if [[ -n "$project" ]]; then
      if printf '%s\n' "$projects" | grep -F -- "$project" >/dev/null 2>&1; then
        pass "Requested project is visible: $project"
      else
        fail "Requested project is not visible: $project"
      fi
    fi
  else
    fail "Run:ai project listing failed: ${projects//$'\n'/, }"
  fi
else
  fail "Run:ai CLI is not installed or not on PATH"
fi

docker_ready=0
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  docker_ready=1
  pass "Docker client can reach the daemon"
elif ((require_docker)); then
  fail "Docker is required but unavailable"
else
  warn "Docker is unavailable; local container validation will be limited"
fi

gpu_ready=0
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
  gpu_ready=1
  gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n 1)
  pass "NVIDIA GPU is visible${gpu_name:+: $gpu_name}"
elif ((require_gpu)); then
  fail "A local NVIDIA GPU is required but unavailable"
else
  warn "No local NVIDIA GPU is visible; use CPU/dry-run validation"
fi

if ((docker_ready)); then
  if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"nvidia"'; then
    pass "Docker has an NVIDIA container runtime"
  elif ((require_gpu)); then
    fail "Docker lacks an NVIDIA container runtime"
  elif ((gpu_ready)); then
    warn "A host GPU exists but Docker lacks an NVIDIA container runtime"
  fi
fi

if [[ -n "$local_output_dir" ]]; then
  if [[ ! -d "$local_output_dir" ]]; then
    fail "Local output directory does not exist: $local_output_dir"
  elif [[ ! -w "$local_output_dir" ]]; then
    fail "Local output directory is not writable: $local_output_dir"
  else
    probe=$(mktemp "$local_output_dir/.runai-preflight.XXXXXX" 2>/dev/null || true)
    if [[ -n "$probe" && -f "$probe" ]]; then
      rm -f -- "$probe"
      pass "Local output directory is writable: $local_output_dir"
    else
      fail "Could not create a probe in: $local_output_dir"
    fi
  fi
fi

printf 'SUMMARY: pass=%d warn=%d fail=%d\n' "$passes" "$warnings" "$failures"
((failures == 0))
