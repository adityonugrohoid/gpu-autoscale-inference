#!/usr/bin/env bash
# full-cycle-run.sh — Comprehensive full-cycle demo with raw event logging
# Captures: K8s events, KEDA scaling, Redis queue, pod lifecycle, node provisioning
# Output: persistent timestamped log in data/
set -euo pipefail

###############################################################################
# Config
###############################################################################
NAMESPACE="llm-gateway"
GATEWAY_IP="${1:-}"
# Both phases fire the IDENTICAL load profile — only the starting state differs
# (Phase 1 fires into a cold system, Phase 2 into a warm one). Every panel
# difference is then provably attributable to cold-vs-warm, with zero confounders.
PHASE1_RATE=5              # Phase 1 = continuous load at this req/s
PHASE1_DURATION=180        # seconds of sustained firing (~900 requests @ 5 rps)
PHASE2_RATE=5              # Phase 2 = same rate
PHASE2_DURATION=180        # same duration. 180s = 12 Prometheus scrape ticks
                           # + 6 KEDA polls — every panel sees the full pattern.
PHASE2_DRAIN_TIMEOUT=300   # safety cap for post-fire drain wait
POLL_INTERVAL=15
COLD_START_TIMEOUT=900     # 15 min max wait for cold start
COOL_DOWN_TIMEOUT=1800     # 30 min max wait for scale-to-zero
VALLEY_GAP=60              # seconds between phase 1 and phase 2
SAMPLE_COUNT=5             # jobs to track for completion
PROMPT="Write a detailed essay about the history of GPU computing and its impact on modern AI infrastructure, covering NVIDIA CUDA, tensor cores, and the evolution from gaming to datacenter workloads."

# Auto-detect kubectl (prefer gcloud SDK to avoid broken Docker Desktop symlinks)
SDK_ROOT=$(gcloud info --format="value(installation.sdk_root)" 2>/dev/null || true)
if [ -n "$SDK_ROOT" ] && [ -f "$SDK_ROOT/bin/kubectl" ]; then
  K="$SDK_ROOT/bin/kubectl"
elif kubectl version --client &>/dev/null 2>&1; then
  K="kubectl"
else
  echo "ERROR: kubectl not found"
  exit 1
fi

# Auto-detect gateway IP if not provided
if [ -z "$GATEWAY_IP" ]; then
  GATEWAY_IP=$("$K" get svc gateway -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [ -z "$GATEWAY_IP" ]; then
    echo "ERROR: No gateway IP found. Pass as argument or ensure LoadBalancer is ready."
    exit 1
  fi
fi
GATEWAY="http://${GATEWAY_IP}"

# Output directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="${SCRIPT_DIR}/../data"
mkdir -p "$DATA_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RUN_DIR="${DATA_DIR}/run-${TIMESTAMP}"
mkdir -p "$RUN_DIR"

# Output files
MAIN_LOG="${RUN_DIR}/full-cycle.log"
EVENTS_LOG="${RUN_DIR}/k8s-events.log"
KEDA_LOG="${RUN_DIR}/keda-events.log"
NODE_LOG="${RUN_DIR}/node-lifecycle.log"
POD_LOG="${RUN_DIR}/pod-lifecycle.log"
REDIS_LOG="${RUN_DIR}/redis-queue.log"
WORKER_LOG="${RUN_DIR}/worker-output.log"
VLLM_LOG="${RUN_DIR}/vllm-output.log"
GPU_RESOURCE_LOG="${RUN_DIR}/gpu-resource-lifecycle.log"
SUMMARY="${RUN_DIR}/summary.log"
TIMELINE="${RUN_DIR}/timeline.log"

# Start time
T0=$(date +%s)

###############################################################################
# Helpers
###############################################################################
ts() {
  local now
  now=$(date +%s)
  local elapsed=$((now - T0))
  echo "T+${elapsed}s ($(date -u +%H:%M:%S))"
}

log() {
  local msg="[$(ts)] $1"
  echo "$msg" | tee -a "$MAIN_LOG"
}

timeline() {
  local event="$1"
  local now
  now=$(date +%s)
  local elapsed=$((now - T0))
  echo "T+${elapsed}s | $(date -u +%Y-%m-%dT%H:%M:%SZ) | ${event}" >> "$TIMELINE"
  log "TIMELINE: ${event}"
}

get_gpu_nodes() {
  # Label-existence selector — GPU-type agnostic. Previously hardcoded
  # `nvidia-l4` which always returned 0 on `nvidia-tesla-t4` nodes and broke
  # the cool-down loop with a premature "GPU NODE REMOVED" event.
  "$K" get nodes -l cloud.google.com/gke-accelerator \
    --no-headers 2>/dev/null | wc -l | tr -d ' '
}

get_pod_status() {
  local app="$1"
  "$K" get pods -n "$NAMESPACE" -l "app=${app}" \
    --no-headers 2>/dev/null | head -1 | awk '{print $2, $3}' || echo "0/0 None"
}

get_pod_count() {
  local app="$1"
  "$K" get pods -n "$NAMESPACE" -l "app=${app}" \
    --no-headers --field-selector=status.phase=Running 2>/dev/null | wc -l | tr -d ' '
}

get_queue_depth() {
  "$K" exec -n "$NAMESPACE" deploy/redis -c redis -- \
    redis-cli LLEN inference_queue 2>/dev/null | tr -d '[:space:]' || echo "0"
}

check_sample_jobs() {
  local done=0
  for jid in "${SAMPLE_JOBS[@]}"; do
    local result
    result=$(curl -s "${GATEWAY}/result/${jid}" 2>/dev/null || echo '{"status":"error"}')
    local status
    status=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','error'))" 2>/dev/null || echo "error")
    if [ "$status" = "done" ] || [ "$status" = "error" ]; then
      done=$((done + 1))
    fi
  done
  echo "$done"
}

###############################################################################
# Background log collectors
###############################################################################
PIDS=()

# K8s events (raw, all namespace events)
"$K" get events -n "$NAMESPACE" --watch-only \
  -o custom-columns='TIME:.lastTimestamp,TYPE:.type,REASON:.reason,OBJECT:.involvedObject.kind/.involvedObject.name,MESSAGE:.message' \
  >> "$EVENTS_LOG" 2>&1 &
PIDS+=($!)

# KEDA-specific events
"$K" get events -n "$NAMESPACE" --watch-only \
  --field-selector reason=KEDAScaleTargetActivated \
  -o custom-columns='TIME:.lastTimestamp,REASON:.reason,OBJECT:.involvedObject.name,MESSAGE:.message' \
  >> "$KEDA_LOG" 2>&1 &
PIDS+=($!)

"$K" get events -n "$NAMESPACE" --watch-only \
  --field-selector reason=KEDAScaleTargetDeactivated \
  -o custom-columns='TIME:.lastTimestamp,REASON:.reason,OBJECT:.involvedObject.name,MESSAGE:.message' \
  >> "$KEDA_LOG" 2>&1 &
PIDS+=($!)

# Node lifecycle (cluster-wide)
"$K" get events --all-namespaces --watch-only \
  --field-selector reason=TriggeredScaleUp \
  -o custom-columns='TIME:.lastTimestamp,REASON:.reason,MESSAGE:.message' \
  >> "$NODE_LOG" 2>&1 &
PIDS+=($!)

"$K" get events --all-namespaces --watch-only \
  --field-selector reason=ScaleDown \
  -o custom-columns='TIME:.lastTimestamp,REASON:.reason,MESSAGE:.message' \
  >> "$NODE_LOG" 2>&1 &
PIDS+=($!)

# Node watcher
"$K" get nodes -w --no-headers -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[-1].type,READY:.status.conditions[-1].status,AGE:.metadata.creationTimestamp' \
  >> "$NODE_LOG" 2>&1 &
PIDS+=($!)

# GPU resource registration timing — captures the exact moment nvidia.com/gpu
# becomes schedulable. Combined with NODE_LOG's Ready=True timestamp, this
# directly measures the device-plugin registration gap (research finding ~59s).
# 2-second poll = sub-3s resolution; cheap (single API call per tick).
echo "# gpu-resource-lifecycle: per-tick capacity/allocatable for accelerator nodes" > "$GPU_RESOURCE_LOG"
(
  while true; do
    "$K" get nodes -l cloud.google.com/gke-accelerator -o jsonpath='{range .items[*]}{.metadata.name}{"|capacity="}{.status.capacity.nvidia\.com/gpu}{"|allocatable="}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null \
      | awk -v t="$(date -u +%Y-%m-%dT%H:%M:%SZ)" 'NF{print t" | "$0}' >> "$GPU_RESOURCE_LOG"
    sleep 2
  done
) &
PIDS+=($!)

# Streaming pod log capture for vLLM and worker. Polls every 3s for pods
# matching the label selector and spawns `kubectl logs -f` against any pod
# we are not already tailing. This survives Spot preemption (replacement
# pod gets a new tail) and pod scale-up/down. PIDs of every spawned tail
# AND the supervisor loop itself are tracked in PIDS so the trap kills them.
#
# Why this fixes the empty-log bug: the previous implementation only ran
# `kubectl logs --tail=200` inside cleanup(), AFTER KEDA had scaled pods
# to zero — pod selectors returned nothing, output was zero bytes.
stream_pod_logs() {
  local app="$1"
  local outfile="$2"
  local seen_file
  seen_file=$(mktemp)
  # When the parent's cleanup kills this supervisor, cascade-kill any tails
  # we spawned. Without this trap, `kubectl logs -f` orphans would survive.
  # shellcheck disable=SC2064
  trap "kill \$(jobs -p) 2>/dev/null; rm -f $seen_file; exit 0" TERM INT EXIT
  echo "# streamed pod logs for app=${app} (started $(date -u +%Y-%m-%dT%H:%M:%SZ))" > "$outfile"
  while true; do
    while IFS= read -r pod; do
      [ -z "$pod" ] && continue
      if ! grep -Fxq "$pod" "$seen_file" 2>/dev/null; then
        echo "$pod" >> "$seen_file"
        {
          echo ""
          echo "=== POD ${pod} START $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
        } >> "$outfile"
        "$K" logs -n "$NAMESPACE" "${pod#pod/}" -f --timestamps=true --all-containers >> "$outfile" 2>&1 &
      fi
    done < <("$K" get pods -n "$NAMESPACE" -l "app=${app}" -o name 2>/dev/null)
    sleep 3
  done
}

stream_pod_logs vllm "$VLLM_LOG" &
PIDS+=($!)
stream_pod_logs worker "$WORKER_LOG" &
PIDS+=($!)

verify_logs_populated() {
  local failed=0
  local f
  for f in "$MAIN_LOG" "$EVENTS_LOG" "$KEDA_LOG" "$NODE_LOG" "$POD_LOG" \
           "$REDIS_LOG" "$VLLM_LOG" "$WORKER_LOG" "$TIMELINE" "$GPU_RESOURCE_LOG"; do
    if [ ! -s "$f" ]; then
      echo "LOG INTEGRITY FAILURE: $(basename "$f") is empty or missing" | tee -a "$MAIN_LOG"
      failed=1
    fi
  done
  if [ "$failed" -eq 0 ]; then
    echo "LOG INTEGRITY OK: all expected log files are non-empty" | tee -a "$MAIN_LOG"
  fi
  return $failed
}

cleanup() {
  log "Cleaning up background processes..."
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  # Capture --previous (terminated) container logs for any pods that the
  # streaming tail couldn't catch (e.g. Spot-preempted pods that exited
  # before the supervisor's 3s poll noticed them).
  log "Capturing --previous logs for terminated pods..."
  for pod in $("$K" get pods -n "$NAMESPACE" -l app=vllm -o name 2>/dev/null); do
    {
      echo ""
      echo "=== ${pod} --previous (post-run capture) ==="
    } >> "$VLLM_LOG"
    "$K" logs -n "$NAMESPACE" "${pod#pod/}" --previous --all-containers --timestamps=true \
      >> "$VLLM_LOG" 2>&1 || true
  done
  for pod in $("$K" get pods -n "$NAMESPACE" -l app=worker -o name 2>/dev/null); do
    {
      echo ""
      echo "=== ${pod} --previous (post-run capture) ==="
    } >> "$WORKER_LOG"
    "$K" logs -n "$NAMESPACE" "${pod#pod/}" --previous --all-containers --timestamps=true \
      >> "$WORKER_LOG" 2>&1 || true
  done
  # Verify all expected log files are non-empty (loud but non-fatal).
  verify_logs_populated || true
}
trap cleanup EXIT

###############################################################################
# Pre-flight
###############################################################################
log "============================================================"
log "FULL-CYCLE RUN — ${TIMESTAMP}"
log "============================================================"
log "Gateway:    ${GATEWAY}"
log "Namespace:  ${NAMESPACE}"
log "Output dir: ${RUN_DIR}"
log ""

# Capture initial state
log "--- PRE-FLIGHT STATE ---"
log "Nodes:"
"$K" get nodes -o wide 2>&1 | tee -a "$MAIN_LOG"
log ""
log "Pods:"
"$K" get pods -n "$NAMESPACE" -o wide 2>&1 | tee -a "$MAIN_LOG"
log ""
log "ScaledObjects:"
"$K" get scaledobjects -n "$NAMESPACE" 2>&1 | tee -a "$MAIN_LOG"
log ""
log "HPAs:"
"$K" get hpa -n "$NAMESPACE" 2>&1 | tee -a "$MAIN_LOG"
log ""

# Health check
HEALTH=$(curl -s "${GATEWAY}/health" 2>/dev/null || echo '{"status":"error"}')
log "Health check: ${HEALTH}"
if ! echo "$HEALTH" | grep -q '"ok"'; then
  log "ERROR: Gateway not healthy. Aborting."
  exit 1
fi

timeline "PRE-FLIGHT COMPLETE — system at zero (no GPU node, no workers, no vLLM)"

###############################################################################
# PHASE 1 — Cold Start Continuous Load
###############################################################################
# Fires the SAME continuous-load profile as Phase 2 (rate × duration), but
# into a cold system (0 pods, 0 GPU node). This makes the two phases directly
# comparable: identical ingress signal, only the starting system state differs.
# Every panel difference between Phase 1 and Phase 2 is then attributable
# purely to cold-vs-warm.
log ""
log "============================================================"
log "PHASE 1: COLD START CONTINUOUS LOAD — ${PHASE1_RATE} req/s × ${PHASE1_DURATION}s"
log "============================================================"
timeline "PHASE 1 START — continuous load: ${PHASE1_RATE} req/s × ${PHASE1_DURATION}s (cold start)"

P1_START_EPOCH=$(date +%s)
P1_FIRE_END=$((P1_START_EPOCH + PHASE1_DURATION))
P1_FIRED=0
P1_SLEEP=$(awk -v r="$PHASE1_RATE" 'BEGIN{printf "%.3f", 1.0/r}')

SAMPLE_JOBS=()
VLLM_READY_TIME=""
COLD_START_SECONDS=""
FIRST_TOKEN_LOGGED=false

# CRITICAL: fire loop must make ZERO blocking kubectl/curl-result calls.
# Previous version interleaved status snapshots with fires; the snapshots
# (kubectl exec redis-cli + 5× curl /result) took >POLL_INTERVAL, causing
# every iteration to re-trigger the snapshot and collapsing fire rate to
# ~0.06 req/s. Fix: fire loop does only `curl /generate`, and a parallel
# background subshell does the status monitoring independently.
P1_FIRED_FILE=$(mktemp)
echo 0 > "$P1_FIRED_FILE"

# Background status monitor — runs independently of fire loop, writes to
# the standard logs so the user sees live progress.
(
  while [ "$(date +%s)" -lt "$P1_FIRE_END" ]; do
    sleep "$POLL_INTERVAL"
    MON_NOW=$(date +%s)
    [ "$MON_NOW" -ge "$P1_FIRE_END" ] && break
    MON_GPU_NODES=$(get_gpu_nodes)
    MON_VLLM_STATUS=$(get_pod_status "vllm")
    MON_WORKER_COUNT=$(get_pod_count "worker")
    MON_QUEUE=$(get_queue_depth)
    MON_FIRED=$(cat "$P1_FIRED_FILE" 2>/dev/null || echo "?")
    MON_T=$(($(date +%s) - T0))
    echo "[T+${MON_T}s ($(date -u +%H:%M:%S))]   P1 FIRING | fired=${MON_FIRED} | gpu_nodes=${MON_GPU_NODES} | vllm=${MON_VLLM_STATUS} | workers=${MON_WORKER_COUNT} | queue=${MON_QUEUE}" | tee -a "$MAIN_LOG"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | queue=${MON_QUEUE}" >> "$REDIS_LOG"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | vllm=${MON_VLLM_STATUS} | workers=${MON_WORKER_COUNT} | gpu_nodes=${MON_GPU_NODES} | phase=1-firing" >> "$POD_LOG"
  done
) &
P1_MONITOR_PID=$!

# Fire loop — ZERO kubectl calls. First SAMPLE_COUNT requests fire
# synchronously so we can capture their job_ids for milestone tracking;
# subsequent requests fire in the background so sleep interval dominates.
while [ "$(date +%s)" -lt "$P1_FIRE_END" ]; do
  if [ ${#SAMPLE_JOBS[@]} -lt "$SAMPLE_COUNT" ]; then
    RESP=$(curl -s -X POST "${GATEWAY}/generate" \
      -H 'Content-Type: application/json' \
      -d "{\"prompt\":\"${PROMPT} Cold continuous ${P1_FIRED}.\"}" 2>/dev/null || echo '{}')
    JID=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('job_id',''))" 2>/dev/null || true)
    if [ -n "$JID" ]; then
      SAMPLE_JOBS+=("$JID")
    fi
  else
    (curl -s -X POST "${GATEWAY}/generate" \
      -H 'Content-Type: application/json' \
      -d "{\"prompt\":\"${PROMPT} Cold continuous ${P1_FIRED}.\"}" \
      > /dev/null 2>&1) &
  fi
  P1_FIRED=$((P1_FIRED + 1))
  echo "$P1_FIRED" > "$P1_FIRED_FILE"
  sleep "$P1_SLEEP"
done

# Stop monitor; give backgrounded curls a moment to drain (do NOT use bare
# `wait` — it would block on the long-running kubectl --watch-only jobs).
kill "$P1_MONITOR_PID" 2>/dev/null || true
sleep 2
rm -f "$P1_FIRED_FILE"
log "PHASE 1 FIRE COMPLETE — ${P1_FIRED} requests fired in ${PHASE1_DURATION}s, waiting for GPU ready + queue drain"
timeline "PHASE 1 FIRE STOP — ${P1_FIRED} requests fired, awaiting cold-start completion"

# Post-fire: wait for queue to drain AND samples complete. GPU may still be
# provisioning at this point — that's expected for cold start.
while true; do
  sleep "$POLL_INTERVAL"
  ELAPSED=$(($(date +%s) - T0))
  if [ "$ELAPSED" -ge "$COLD_START_TIMEOUT" ]; then
    log "COLD START TIMEOUT at ${COLD_START_TIMEOUT}s — breaking"
    timeline "PHASE 1 TIMEOUT at ${COLD_START_TIMEOUT}s"
    break
  fi

  GPU_NODES=$(get_gpu_nodes)
  VLLM_STATUS=$(get_pod_status "vllm")
  WORKER_COUNT=$(get_pod_count "worker")
  QUEUE=$(get_queue_depth)
  SAMPLE_DONE=$(check_sample_jobs)

  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | queue=${QUEUE}" >> "$REDIS_LOG"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | vllm=${VLLM_STATUS} | workers=${WORKER_COUNT} | gpu_nodes=${GPU_NODES} | phase=1-drain" >> "$POD_LOG"

  log "  $(ts) | P1 DRAIN | gpu_nodes=${GPU_NODES} | vllm=${VLLM_STATUS} | workers=${WORKER_COUNT} | queue=${QUEUE} | sample_done=${SAMPLE_DONE}/${SAMPLE_COUNT}"

  # Milestone: vLLM ready (may happen during drain, not during fire)
  if [ "$GPU_NODES" -ge 1 ] && [ -z "$VLLM_READY_TIME" ] && echo "$VLLM_STATUS" | grep -q "1/1"; then
    VLLM_READY_TIME=$(date +%s)
    COLD_START_SECONDS=$((VLLM_READY_TIME - T0))
    timeline "vLLM READY — cold start = ${COLD_START_SECONDS}s"
  fi

  # Milestone: first completions
  if [ "$SAMPLE_DONE" = "$SAMPLE_COUNT" ] && [ "$FIRST_TOKEN_LOGGED" = "false" ]; then
    FIRST_TOKEN_LOGGED=true
    timeline "PHASE 1 ALL SAMPLES COMPLETE — first completions at T+${ELAPSED}s"
  fi

  # Done: queue empty AND all samples complete
  if [ "$QUEUE" -eq 0 ] && [ "$SAMPLE_DONE" -ge "$SAMPLE_COUNT" ]; then
    break
  fi
done

PHASE1_END=$(($(date +%s) - T0))
timeline "PHASE 1 DONE — ${PHASE1_END}s total, ${P1_FIRED} requests fired"

# Capture K8s events snapshot
log ""
log "--- PHASE 1 K8S EVENTS SNAPSHOT ---"
"$K" get events -n "$NAMESPACE" --sort-by='.lastTimestamp' \
  -o custom-columns='AGE:.metadata.creationTimestamp,TYPE:.type,REASON:.reason,OBJECT:.involvedObject.kind/.involvedObject.name,MESSAGE:.message' \
  2>&1 | tee -a "$MAIN_LOG"

# Capture cluster autoscaler status
log ""
log "--- CLUSTER AUTOSCALER STATUS ---"
"$K" get configmap cluster-autoscaler-status -n kube-system -o jsonpath='{.data.status}' \
  2>&1 | tee -a "$MAIN_LOG"
echo "" | tee -a "$MAIN_LOG"

###############################################################################
# VALLEY GAP
###############################################################################
log ""
log "============================================================"
log "VALLEY GAP — sleeping ${VALLEY_GAP}s to create visible gap in metrics"
log "============================================================"
timeline "VALLEY GAP START — ${VALLEY_GAP}s pause"
sleep "$VALLEY_GAP"
timeline "VALLEY GAP END"

###############################################################################
# PHASE 2 — Warm Continuous Load
###############################################################################
# Instead of a one-shot burst (which drains in ~23s, faster than the 15s
# Prometheus scrape interval and 30s KEDA polling), Phase 2 fires at a sustained
# rate for PHASE2_DURATION seconds. This creates a FLAT-TOP pattern on all
# throughput/utilization panels — visually distinct from Phase 1's cold-start
# ramp-and-plateau shape, and directly shows continuous warm-GPU serving.
log ""
log "============================================================"
log "PHASE 2: WARM CONTINUOUS LOAD — ${PHASE2_RATE} req/s × ${PHASE2_DURATION}s"
log "============================================================"

# Capture state at fire time
GPU_NODES=$(get_gpu_nodes)
WORKER_COUNT=$(get_pod_count "worker")
VLLM_PODS=$(get_pod_count "vllm")
log "State at fire: gpu_nodes=${GPU_NODES} workers=${WORKER_COUNT} vllm=${VLLM_PODS}"
timeline "PHASE 2 START — continuous load: ${PHASE2_RATE} req/s × ${PHASE2_DURATION}s (warm GPU)"

P2_START=$(($(date +%s) - T0))
P2_START_EPOCH=$(date +%s)
P2_FIRE_END=$((P2_START_EPOCH + PHASE2_DURATION))
P2_FIRED=0
P2_SLEEP=$(awk -v r="$PHASE2_RATE" 'BEGIN{printf "%.3f", 1.0/r}')
P2_FIRED_FILE=$(mktemp)
echo 0 > "$P2_FIRED_FILE"

# Background status monitor (see Phase 1 for rationale)
(
  while [ "$(date +%s)" -lt "$P2_FIRE_END" ]; do
    sleep "$POLL_INTERVAL"
    MON_NOW=$(date +%s)
    [ "$MON_NOW" -ge "$P2_FIRE_END" ] && break
    MON_GPU_NODES=$(get_gpu_nodes)
    MON_VLLM_STATUS=$(get_pod_status "vllm")
    MON_WORKER_COUNT=$(get_pod_count "worker")
    MON_QUEUE=$(get_queue_depth)
    MON_FIRED=$(cat "$P2_FIRED_FILE" 2>/dev/null || echo "?")
    MON_T=$(($(date +%s) - T0))
    echo "[T+${MON_T}s ($(date -u +%H:%M:%S))]   P2 FIRING | fired=${MON_FIRED} | gpu_nodes=${MON_GPU_NODES} | vllm=${MON_VLLM_STATUS} | workers=${MON_WORKER_COUNT} | queue=${MON_QUEUE}" | tee -a "$MAIN_LOG"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | queue=${MON_QUEUE}" >> "$REDIS_LOG"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | vllm=${MON_VLLM_STATUS} | workers=${MON_WORKER_COUNT} | gpu_nodes=${MON_GPU_NODES} | phase=2-firing" >> "$POD_LOG"
  done
) &
P2_MONITOR_PID=$!

# Fire loop — ZERO kubectl calls, backgrounded curls
while [ "$(date +%s)" -lt "$P2_FIRE_END" ]; do
  (curl -s -X POST "${GATEWAY}/generate" \
    -H 'Content-Type: application/json' \
    -d "{\"prompt\":\"${PROMPT} Warm continuous ${P2_FIRED}.\"}" \
    > /dev/null 2>&1) &
  P2_FIRED=$((P2_FIRED + 1))
  echo "$P2_FIRED" > "$P2_FIRED_FILE"
  sleep "$P2_SLEEP"
done

kill "$P2_MONITOR_PID" 2>/dev/null || true
sleep 2
rm -f "$P2_FIRED_FILE"
log "PHASE 2 FIRE COMPLETE — ${P2_FIRED} requests fired in ${PHASE2_DURATION}s, entering drain"
timeline "PHASE 2 FIRE STOP — ${P2_FIRED} requests fired, queue draining"

# Post-fire drain — wait for queue to clear
DRAIN_START=$(date +%s)
while true; do
  sleep "$POLL_INTERVAL"
  QUEUE=$(get_queue_depth)
  WC=$(get_pod_count "worker")
  VC=$(get_pod_count "vllm")
  D_ELAPSED=$(($(date +%s) - DRAIN_START))

  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | queue=${QUEUE}" >> "$REDIS_LOG"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | vllm=${VC} | workers=${WC} | phase=2-drain" >> "$POD_LOG"

  log "  $(ts) | P2 DRAIN | queue=${QUEUE} | vllm=${VC} | workers=${WC} | drain_elapsed=${D_ELAPSED}s"

  if [ "$QUEUE" -eq 0 ]; then
    break
  fi
  if [ "$D_ELAPSED" -ge "$PHASE2_DRAIN_TIMEOUT" ]; then
    log "PHASE 2 DRAIN TIMEOUT at ${PHASE2_DRAIN_TIMEOUT}s — breaking"
    break
  fi
done

P2_END=$(($(date +%s) - T0))
P2_DURATION=$((P2_END - P2_START))
timeline "PHASE 2 DONE — ${P2_DURATION}s total (warm response time)"

###############################################################################
# COOL DOWN — Wait for scale-to-zero
###############################################################################
log ""
log "============================================================"
log "COOL DOWN — waiting for pods + GPU node to scale to zero"
log "============================================================"
timeline "COOL DOWN START"

PODS_ZERO_TIME=""
GPU_ZERO_TIME=""
CD_START=$(date +%s)

while true; do
  ELAPSED_CD=$(($(date +%s) - CD_START))
  if [ "$ELAPSED_CD" -ge "$COOL_DOWN_TIMEOUT" ]; then
    log "TIMEOUT: Cool down exceeded ${COOL_DOWN_TIMEOUT}s"
    timeline "COOL DOWN TIMEOUT at ${COOL_DOWN_TIMEOUT}s"
    break
  fi

  sleep "$POLL_INTERVAL"

  GPU_NODES=$(get_gpu_nodes)
  VLLM_PODS=$(get_pod_count "vllm")
  WORKER_PODS=$(get_pod_count "worker")
  QUEUE=$(get_queue_depth)

  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | queue=${QUEUE}" >> "$REDIS_LOG"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | vllm=${VLLM_PODS} | workers=${WORKER_PODS} | gpu_nodes=${GPU_NODES}" >> "$POD_LOG"

  log "  $(ts) | gpu_nodes=${GPU_NODES} | vllm=${VLLM_PODS} | workers=${WORKER_PODS}"

  # Detect pod scale-to-zero
  if [ "$VLLM_PODS" -eq 0 ] && [ "$WORKER_PODS" -eq 0 ] && [ -z "$PODS_ZERO_TIME" ]; then
    PODS_ZERO_TIME=$(($(date +%s) - T0))
    timeline "PODS SCALED TO ZERO — KEDA cooldown complete at T+${PODS_ZERO_TIME}s"
  fi

  # Detect GPU node removal
  if [ "$GPU_NODES" -eq 0 ] && [ -z "$GPU_ZERO_TIME" ]; then
    GPU_ZERO_TIME=$(($(date +%s) - T0))
    timeline "GPU NODE REMOVED — Cluster Autoscaler scale-down at T+${GPU_ZERO_TIME}s"
  fi

  # Done: everything at zero
  if [ "$GPU_NODES" -eq 0 ] && [ "$VLLM_PODS" -eq 0 ] && [ "$WORKER_PODS" -eq 0 ]; then
    break
  fi
done

timeline "COOL DOWN COMPLETE — full zero state"

###############################################################################
# Final captures
###############################################################################
log ""
log "--- FINAL K8S EVENTS ---"
"$K" get events -n "$NAMESPACE" --sort-by='.lastTimestamp' \
  -o custom-columns='AGE:.metadata.creationTimestamp,TYPE:.type,REASON:.reason,OBJECT:.involvedObject.kind/.involvedObject.name,MESSAGE:.message' \
  2>&1 | tee -a "$MAIN_LOG"

log ""
log "--- FINAL NODES ---"
"$K" get nodes -o wide 2>&1 | tee -a "$MAIN_LOG"

log ""
log "--- FINAL PODS ---"
"$K" get pods -n "$NAMESPACE" -o wide 2>&1 | tee -a "$MAIN_LOG"

log ""
log "--- CLUSTER AUTOSCALER FINAL STATUS ---"
"$K" get configmap cluster-autoscaler-status -n kube-system -o jsonpath='{.data.status}' \
  2>&1 | tee -a "$MAIN_LOG"
echo "" | tee -a "$MAIN_LOG"

###############################################################################
# Summary
###############################################################################
{
  echo "============================================================"
  echo "FULL-CYCLE RUN SUMMARY — ${TIMESTAMP}"
  echo "============================================================"
  echo ""
  echo "Cluster:     GKE llm-gateway (us-east1-d)"
  echo "GPU:         NVIDIA T4 Spot (n1-standard-4)"
  echo "Model:       Qwen/Qwen2.5-1.5B-Instruct"
  echo "Gateway:     ${GATEWAY}"
  echo ""
  echo "Load profile:       ${PHASE1_RATE} req/s × ${PHASE1_DURATION}s (both phases identical)"
  echo ""
  echo "--- PHASE 1: COLD START CONTINUOUS LOAD ---"
  echo "Requests fired:     ${P1_FIRED}"
  echo "Cold start (vLLM):  ${COLD_START_SECONDS:-N/A}s"
  echo "Phase 1 total:      ${PHASE1_END}s"
  echo ""
  echo "--- PHASE 2: WARM CONTINUOUS LOAD ---"
  echo "Requests fired:     ${P2_FIRED}"
  echo "Total P2 duration:  ${P2_DURATION}s (fire + drain)"
  echo ""
  echo "--- COOL DOWN ---"
  echo "Pods to zero:       ${PODS_ZERO_TIME:-N/A}s (from T+0)"
  echo "GPU node removed:   ${GPU_ZERO_TIME:-N/A}s (from T+0)"
  echo ""
  echo "--- OUTPUT FILES (size in bytes) ---"
  for f in "$MAIN_LOG" "$EVENTS_LOG" "$KEDA_LOG" "$NODE_LOG" "$POD_LOG" \
           "$REDIS_LOG" "$WORKER_LOG" "$VLLM_LOG" "$GPU_RESOURCE_LOG" \
           "$TIMELINE" "$SUMMARY"; do
    if [ -e "$f" ]; then
      printf "  %-30s %10d bytes\n" "$(basename "$f")" "$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f" 2>/dev/null || echo 0)"
    else
      printf "  %-30s %10s\n" "$(basename "$f")" "MISSING"
    fi
  done
} | tee "$SUMMARY"

log ""
log "============================================================"
log "RUN COMPLETE — all output in ${RUN_DIR}"
log "============================================================"
