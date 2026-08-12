#!/bin/bash
# Create a Brev Launchable and validate its exposed services end to end.
#
# Measured on 2026-08-12 against the Isaac Lab 2.3.2 + ROS 2 Jazzy launchable
# (env-3HmXnNzoex3D9hUuIyUDkeFJbT4). A clean deploy takes ~28 minutes and looks
# broken for most of it. The timeline from an untouched instance:
#
#   10:24  VM boots, brev create returns
#   10:29  build_status=COMPLETED        <- setup script is still running
#   10:36  setup script writes compose.yaml, starts `docker compose up -d`
#   10:36..10:52  ~30GB image pull; nvidia-smi reports "Driver/library version
#                 mismatch" the whole time (580 userspace installed over the
#                 base image's loaded 595 kernel module), the unit's
#                 ExecStartPre=nvidia-smi fails, no container exists
#   10:52  the script's own `shutdown -r +1` fires; VM reboots, 580 loads
#   ~10:54 systemd unit starts Compose, container runs, all ports serve
#
# So DO NOT intervene on a driver mismatch or a missing container: both are the
# normal mid-setup state. An earlier version of this script rebooted on seeing
# the mismatch and pre-empted the VM's own reboot by ~2 minutes, then reported
# a healthy launchable as broken. This version only waits and observes.
#
# Two things that are still true and worth encoding:
#  - build_status=COMPLETED fires while the setup script is still running, so it
#    is necessary but NOT sufficient before probing services.
#  - `brev exec` and `brev port-forward` target port 22, which is firewalled on
#    AWS g6e; direct TCP to :22 times out. Brev's own ~/.brev/ssh_config exposes
#    the working relay (global.prd.ga.run.brev.nvidia.com) under the bare
#    instance-name alias, so everything here uses plain ssh/ssh -L. That config
#    is only written once the instance exists, so `brev refresh` must run after
#    creation, not before.
#
# Usage:
#   launchable_test.sh --launchable env-XXXX [--name NAME] [--delete]
#   launchable_test.sh --existing NAME [--delete] [--force-recover] [--skip-workload]
#   launchable_test.sh --launchable env-YYYY --port-offset 10000   # concurrent run
#
# Exit: 0 all services passed, 1 a check failed, 2 setup/timeout error.

set -uo pipefail

BREV="${BREV_BIN:-$HOME/.local/bin/brev}"
LAUNCHABLE=""; NAME=""; EXISTING=""; DELETE=0; FORCE_RECOVER=0; SKIP_WORKLOAD=0
BUILD_TIMEOUT="${BUILD_TIMEOUT:-3600}"
SSH_TIMEOUT="${SSH_TIMEOUT:-900}"
CONVERGE_TIMEOUT="${CONVERGE_TIMEOUT:-2700}"   # ~28min observed; allow headroom
# Local tunnel ports are fixed, so two concurrent runs would collide on them.
# Offset one of them (e.g. --port-offset 10000) to test two Launchables at once.
PORT_OFFSET="${PORT_OFFSET:-0}"

while [ $# -gt 0 ]; do
  case "$1" in
    --launchable)   LAUNCHABLE="$2"; shift 2 ;;
    --name)         NAME="$2"; shift 2 ;;
    --existing)     EXISTING="$2"; shift 2 ;;
    --delete)       DELETE=1; shift ;;
    --force-recover) FORCE_RECOVER=1; shift ;;
    --skip-workload) SKIP_WORKLOAD=1; shift ;;
    --port-offset)  PORT_OFFSET="$2"; shift 2 ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
done

STAMP="$(date -u +%Y%m%dt%H%M%SZ)"
# Evidence belongs in the gitignored artifacts/ tree, not next to this script.
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="$REPO_ROOT/artifacts/brev/raw/evidence/$STAMP"
mkdir -p "$OUT"
TUNNEL_PID=""

log() { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$OUT/run.log"; }

cleanup() {
  [ -n "$TUNNEL_PID" ] && kill "$TUNNEL_PID" 2>/dev/null
  if [ "$DELETE" = "1" ] && [ -n "${NAME:-}" ]; then
    log "deleting $NAME"
    "$BREV" delete "$NAME" >>"$OUT/delete.log" 2>&1 || \
      log "!! DELETE FAILED -- verify: brev ls --all | grep $NAME"
  elif [ -n "${NAME:-}" ]; then
    log "instance $NAME left RUNNING and billing. Delete with: brev delete $NAME"
  fi
}
trap cleanup EXIT

ssh_do() { ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=no "$NAME" "$@" 2>&1 | grep -v "Pseudo-terminal"; }

# `brev ls --json` wraps its array in {"workspaces": [...]}; tolerate a bare array.
field() {
  "$BREV" ls --all --json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
rows=d if isinstance(d,list) else d.get('workspaces') or d.get('instances') or []
for r in rows:
    if r.get('name')=='$1': print(r.get('$2','')); break
"
}

wait_ssh() {
  local start; start=$(date -u +%s)
  while :; do
    ssh_do "echo up" 2>/dev/null | grep -q up && return 0
    [ $(( $(date -u +%s) - start )) -ge "$1" ] && return 1
    sleep 10
  done
}

# --- preflight -------------------------------------------------------------
[ -x "$BREV" ] || { log "brev not found at $BREV"; exit 2; }
"$BREV" ls >/dev/null 2>&1 || { log "brev auth is dead; re-login and retry"; exit 2; }
log "brev $("$BREV" --version 2>/dev/null | tr -d '\n')"

# --- create or adopt -------------------------------------------------------
if [ -n "$EXISTING" ]; then
  NAME="$EXISTING"
  [ -n "$(field "$NAME" status)" ] || { log "no such instance: $NAME"; exit 2; }
  log "adopting existing instance $NAME"
else
  [ -n "$LAUNCHABLE" ] || { log "need --launchable or --existing"; exit 2; }
  [ -n "$NAME" ] || NAME="agent-lt-$(date -u +%H%M%S)"
  log "creating $NAME from $LAUNCHABLE"
  "$BREV" create "$NAME" --launchable "$LAUNCHABLE" --timeout 900 >"$OUT/create.log" 2>&1 || {
    log "create failed, see $OUT/create.log"; exit 2; }
  log "created (VM ready); type=$(field "$NAME" instance_type) gpu=$(field "$NAME" gpu)"
fi

# --- gate 1: setup script finished ----------------------------------------
log "waiting for build_status=COMPLETED (timeout ${BUILD_TIMEOUT}s)"
start=$(date -u +%s); last=""
while :; do
  bs="$(field "$NAME" build_status)"
  [ "$bs" != "$last" ] && { log "  build_status=$bs"; last="$bs"; }
  case "$bs" in
    COMPLETED) break ;;
    FAILED|ERROR) log "build failed: $bs"; exit 2 ;;
  esac
  [ $(( $(date -u +%s)-start )) -ge "$BUILD_TIMEOUT" ] && { log "build timeout"; exit 2; }
  sleep 20
done
log "build completed"

# --- gate 2: ssh over the relay (NOT brev exec) ---------------------------
"$BREV" refresh >/dev/null 2>&1   # writes ~/.brev/ssh_config; only valid once the instance exists
log "waiting for ssh (relay :16940 via ~/.brev/ssh_config alias)"
wait_ssh "$SSH_TIMEOUT" || { log "ssh unreachable after ${SSH_TIMEOUT}s"; exit 2; }
log "ssh ready"

# --- gate 3: wait for the launchable to converge, WITHOUT intervening -----
# A driver mismatch and a missing container are the expected mid-setup state
# while the image pulls and before the script's own reboot. Just watch.
log "waiting for convergence: own reboot + running container (timeout ${CONVERGE_TIMEOUT}s)"
start=$(date -u +%s); FIRST_BOOT=""; REBOOTED=0
while :; do
  snap="$(ssh_do 'echo "phase=$(cat /var/lib/isaac-lab-ex-ros2-setup.state 2>/dev/null || echo none)"; echo "boot=$(uptime -s)"; echo "containers=$(sudo docker ps -q 2>/dev/null | wc -l)"; echo "svc=$(systemctl is-active isaac-lab-ex-ros2.service 2>&1)"; echo "nv=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>&1 | head -1)"; echo "dockersz=$(sudo du -sm /var/lib/docker 2>/dev/null | cut -f1)"')"
  boot="$(echo "$snap" | sed -n 's/^boot=//p')"
  cont="$(echo "$snap" | sed -n 's/^containers=//p' | tr -dc '0-9')"
  if [ -n "$boot" ]; then
    [ -z "$FIRST_BOOT" ] && { FIRST_BOOT="$boot"; log "  first boot: $FIRST_BOOT"; }
    if [ "$boot" != "$FIRST_BOOT" ] && [ "$REBOOTED" = "0" ]; then
      REBOOTED=1; log "  *** VM rebooted on its own: $FIRST_BOOT -> $boot ***"
    fi
  fi
  log "  $(echo "$snap" | tr '\n' ' ')"
  if [ -n "$cont" ] && [ "$cont" -ge 1 ]; then
    log "converged after $(( $(date -u +%s)-start ))s (self-reboot=$REBOOTED)"; break
  fi
  if [ $(( $(date -u +%s)-start )) -ge "$CONVERGE_TIMEOUT" ]; then
    log "did not converge within ${CONVERGE_TIMEOUT}s (self-reboot=$REBOOTED)"
    if [ "$FORCE_RECOVER" = "1" ]; then
      log "--force-recover: rebooting as a last resort"
      ssh_do "sudo systemctl reboot" >/dev/null 2>&1; sleep 45
      wait_ssh "$SSH_TIMEOUT" || { log "ssh did not return"; exit 2; }
      start=$(date -u +%s); FORCE_RECOVER=0; continue
    fi
    exit 1
  fi
  sleep 30
done
ssh_do "nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv" >"$OUT/nvidia-smi.log" 2>&1
log "GPU: $(tail -1 "$OUT/nvidia-smi.log")"
ssh_do "sudo docker ps --format '{{.Names}}\t{{.Status}}'" | tee "$OUT/docker-ps.log"

# --- service probes over one multiplexed ssh -L tunnel --------------------
# name:remote:local:kind
SERVICES=(
  "jupyter:8888:18888:http"
  "vscode:8080:18080:http"
  "novnc:6080:16080:http"
  "vnc:5900:15900:tcp"
  "ssh-in-container:2222:12222:tcp"
)
FWD=()
for s in "${SERVICES[@]}"; do IFS=: read -r _ r l _ <<<"$s"; FWD+=(-L "$((l+PORT_OFFSET)):localhost:$r"); done

log "opening ssh tunnel for ${#SERVICES[@]} services"
ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=no -N "${FWD[@]}" "$NAME" \
  >"$OUT/tunnel.log" 2>&1 &
TUNNEL_PID=$!
sleep 8

probe_http() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://localhost:$1/"; }
probe_tcp() {
  python3 -c "
import socket
try:
    s=socket.create_connection(('127.0.0.1',$1),timeout=8)
    print(s.recv(32).decode('utf-8','replace').strip() or 'CONNECTED')
except Exception as e: print('FAIL:',e)
"
}

RESULTS=(); FAILED=0
for svc in "${SERVICES[@]}"; do
  IFS=: read -r sname remote local kind <<<"$svc"
  local=$((local+PORT_OFFSET))
  ok=""
  for _ in $(seq 1 20); do
    if [ "$kind" = http ]; then
      code="$(probe_http "$local")"
      case "$code" in 2??|3??|401) ok="HTTP $code"; break ;; esac
    else
      out="$(probe_tcp "$local")"
      case "$out" in FAIL:*) ;; *) ok="$out"; break ;; esac
    fi
    sleep 6
  done
  if [ -n "$ok" ]; then RESULTS+=("PASS  $sname ($remote)  $ok"); log "  PASS $sname -> $ok"
  else RESULTS+=("FAIL  $sname ($remote)  no response"); FAILED=1; log "  FAIL $sname"; fi
done

kill "$TUNNEL_PID" 2>/dev/null; TUNNEL_PID=""

# --- gate 5: an actual GPU workload ---------------------------------------
# Serving ports prove the container runs; they do NOT prove Isaac Sim can
# initialize. Kit needs GPU passthrough + Vulkan + shader compilation inside
# the container, any of which can fail while all five ports still answer 200.
if [ "$SKIP_WORKLOAD" = "0" ]; then
  CONTAINER="$(ssh_do "sudo docker ps --format '{{.Names}}' | head -1" | tr -d '\r\n ')"
  log "workload smoke test in $CONTAINER (cold shader cache: several minutes)"
  ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30 "$NAME" \
    "sudo docker exec -i $CONTAINER bash -s" >"$OUT/isaac-smoke.log" 2>&1 <<'SMOKE'
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
/root/isaacsim/python.sh - <<'PY'
from isaacsim import SimulationApp
app = SimulationApp({"headless": True})
print("ISAAC_SIM_INIT_OK", flush=True)
app.close()
PY
cd /root/IsaacLab
./isaaclab.sh -p -u scripts/reinforcement_learning/rl_games/train.py \
  --task=Isaac-Cartpole-v0 --headless --max_iterations=3
echo "isaaclab_exit=$?"
SMOKE

  if grep -q "ISAAC_SIM_INIT_OK" "$OUT/isaac-smoke.log"; then
    RESULTS+=("PASS  isaac-sim-init  headless SimulationApp")
    log "  PASS isaac sim init"
  else
    RESULTS+=("FAIL  isaac-sim-init  see isaac-smoke.log"); FAILED=1; log "  FAIL isaac sim init"
  fi
  if grep -q "^isaaclab_exit=0" "$OUT/isaac-smoke.log"; then
    fps="$(grep -oE 'fps total: [0-9]+' "$OUT/isaac-smoke.log" | tail -1)"
    RESULTS+=("PASS  isaac-lab-train  cartpole 3 iters, $fps")
    log "  PASS isaac lab training ($fps)"
  else
    RESULTS+=("FAIL  isaac-lab-train  see isaac-smoke.log"); FAILED=1; log "  FAIL isaac lab training"
  fi
fi

{
  echo "instance:   $NAME"
  echo "type:       $(field "$NAME" instance_type)   gpu: $(field "$NAME" gpu)"
  echo "launchable: ${LAUNCHABLE:-<adopted existing>}"
  echo "gpu check:  $(tail -1 "$OUT/nvidia-smi.log")"
  echo "timestamp:  $STAMP"
  echo
  printf '%s\n' "${RESULTS[@]}"
} | tee "$OUT/summary.txt"

log "evidence: $OUT"
[ "$FAILED" = "0" ] || exit 1
exit 0
