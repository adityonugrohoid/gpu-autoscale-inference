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
PHASE1_REQUESTS=30
PHASE2_REQUESTS=100
POLL_INTERVAL=15
COLD_START_TIMEOUT=900    # 15 min max wait for cold start
COOL_DOWN_TIMEOUT=1800    # 30 min max wait for scale-to-zero
VALLEY_GAP=60             # seconds between phase 1 and phase 2
SAMPLE_COUNT=5            # jobs to track for completion
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
  "$K" get nodes -l cloud.google.com/gke-accelerator=nvidia-l4 \
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

cleanup() {
  log "Cleaning up background processes..."
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  # Capture final pod logs
  log "Capturing final pod logs..."
  "$K" logs -n "$NAMESPACE" -l app=worker --all-containers --tail=200 \
    >> "$WORKER_LOG" 2>/dev/null || true
  "$K" logs -n "$NAMESPACE" -l app=vllm --all-containers --tail=200 \
    >> "$VLLM_LOG" 2>/dev/null || true
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
# PHASE 1 — Cold Start
###############################################################################
log ""
log "============================================================"
log "PHASE 1: COLD START — firing ${PHASE1_REQUESTS} requests"
log "============================================================"
timeline "PHASE 1 START — firing ${PHASE1_REQUESTS} requests (cold start)"

# Fire requests
SAMPLE_JOBS=()
ALL_JOBS=()
for i in $(seq 1 "$PHASE1_REQUESTS"); do
  RESP=$(curl -s -X POST "${GATEWAY}/generate" \
    -H 'Content-Type: application/json' \
    -d "{\"prompt\":\"${PROMPT} Part ${i} of ${PHASE1_REQUESTS}.\"}" 2>/dev/null || echo '{}')
  JID=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('job_id',''))" 2>/dev/null || true)
  if [ -n "$JID" ]; then
    ALL_JOBS+=("$JID")
    if [ ${#SAMPLE_JOBS[@]} -lt "$SAMPLE_COUNT" ]; then
      SAMPLE_JOBS+=("$JID")
    fi
  fi
done

log "Queued ${#ALL_JOBS[@]} jobs (tracking ${#SAMPLE_JOBS[@]} samples)"
timeline "PHASE 1 QUEUED — ${#ALL_JOBS[@]} jobs in inference_queue"

# Poll until vLLM is ready and samples complete
VLLM_READY_TIME=""
COLD_START_SECONDS=""
ELAPSED=0
FIRST_TOKEN_LOGGED=false

while [ "$ELAPSED" -lt "$COLD_START_TIMEOUT" ]; do
  sleep "$POLL_INTERVAL"
  ELAPSED=$(($(date +%s) - T0))

  GPU_NODES=$(get_gpu_nodes)
  VLLM_STATUS=$(get_pod_status "vllm")
  WORKER_COUNT=$(get_pod_count "worker")
  QUEUE=$(get_queue_depth)
  SAMPLE_DONE=$(check_sample_jobs)

  # Redis queue log
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | queue=${QUEUE}" >> "$REDIS_LOG"

  # Pod lifecycle log
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | vllm=${VLLM_STATUS} | workers=${WORKER_COUNT} | gpu_nodes=${GPU_NODES}" >> "$POD_LOG"

  STATUS_LINE="gpu_nodes=${GPU_NODES} | vllm=${VLLM_STATUS} | workers=${WORKER_COUNT} | queue=${QUEUE} | sample_done=${SAMPLE_DONE}/${SAMPLE_COUNT}"
  log "  $(ts) | ${STATUS_LINE}"

  # Detect milestones
  if [ "$GPU_NODES" -ge 1 ] && [ -z "$VLLM_READY_TIME" ] && echo "$VLLM_STATUS" | grep -q "1/1"; then
    VLLM_READY_TIME=$(date +%s)
    COLD_START_SECONDS=$((VLLM_READY_TIME - T0))
    timeline "vLLM READY — cold start = ${COLD_START_SECONDS}s"
  fi

  if [ "$SAMPLE_DONE" = "$SAMPLE_COUNT" ] && [ "$FIRST_TOKEN_LOGGED" = "false" ]; then
    FIRST_TOKEN_LOGGED=true
    timeline "PHASE 1 ALL SAMPLES COMPLETE — first completions at T+${ELAPSED}s"
  fi

  # Done condition: all samples complete
  if [ "$SAMPLE_DONE" -ge "$SAMPLE_COUNT" ]; then
    break
  fi
done

PHASE1_END=$(($(date +%s) - T0))
timeline "PHASE 1 DONE — ${PHASE1_END}s total"

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
# PHASE 2 — Warm Response
###############################################################################
log ""
log "============================================================"
log "PHASE 2: WARM RESPONSE — firing ${PHASE2_REQUESTS} requests"
log "============================================================"

# Capture state at fire time
GPU_NODES=$(get_gpu_nodes)
WORKER_COUNT=$(get_pod_count "worker")
VLLM_PODS=$(get_pod_count "vllm")
log "State at fire: gpu_nodes=${GPU_NODES} workers=${WORKER_COUNT} vllm=${VLLM_PODS}"
timeline "PHASE 2 START — firing ${PHASE2_REQUESTS} requests (warm GPU)"

# Fire requests
SAMPLE_JOBS=()
ALL_JOBS_P2=()
for i in $(seq 1 "$PHASE2_REQUESTS"); do
  RESP=$(curl -s -X POST "${GATEWAY}/generate" \
    -H 'Content-Type: application/json' \
    -d "{\"prompt\":\"${PROMPT} Warm run part ${i} of ${PHASE2_REQUESTS}.\"}" 2>/dev/null || echo '{}')
  JID=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('job_id',''))" 2>/dev/null || true)
  if [ -n "$JID" ]; then
    ALL_JOBS_P2+=("$JID")
    if [ ${#SAMPLE_JOBS[@]} -lt "$SAMPLE_COUNT" ]; then
      SAMPLE_JOBS+=("$JID")
    fi
  fi
done

P2_START=$(($(date +%s) - T0))
log "Queued ${#ALL_JOBS_P2[@]} jobs"
timeline "PHASE 2 QUEUED — ${#ALL_JOBS_P2[@]} jobs"

# Poll until samples complete
while true; do
  sleep "$POLL_INTERVAL"
  QUEUE=$(get_queue_depth)
  SAMPLE_DONE=$(check_sample_jobs)

  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | queue=${QUEUE}" >> "$REDIS_LOG"

  log "  $(ts) | queue=${QUEUE} | sample_done=${SAMPLE_DONE}/${SAMPLE_COUNT}"

  if [ "$SAMPLE_DONE" -ge "$SAMPLE_COUNT" ]; then
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
  echo "--- PHASE 1: COLD START ---"
  echo "Requests fired:     ${PHASE1_REQUESTS}"
  echo "Cold start (vLLM):  ${COLD_START_SECONDS:-N/A}s"
  echo "Phase 1 total:      ${PHASE1_END}s"
  echo ""
  echo "--- PHASE 2: WARM RESPONSE ---"
  echo "Requests fired:     ${PHASE2_REQUESTS}"
  echo "Warm response:      ${P2_DURATION}s"
  echo ""
  echo "--- COOL DOWN ---"
  echo "Pods to zero:       ${PODS_ZERO_TIME:-N/A}s (from T+0)"
  echo "GPU node removed:   ${GPU_ZERO_TIME:-N/A}s (from T+0)"
  echo ""
  echo "--- OUTPUT FILES ---"
  echo "Main log:           ${MAIN_LOG}"
  echo "K8s events (raw):   ${EVENTS_LOG}"
  echo "KEDA events:        ${KEDA_LOG}"
  echo "Node lifecycle:     ${NODE_LOG}"
  echo "Pod lifecycle:      ${POD_LOG}"
  echo "Redis queue:        ${REDIS_LOG}"
  echo "Worker logs:        ${WORKER_LOG}"
  echo "vLLM logs:          ${VLLM_LOG}"
  echo "Timeline:           ${TIMELINE}"
  echo "Summary:            ${SUMMARY}"
} | tee "$SUMMARY"

log ""
log "============================================================"
log "RUN COMPLETE — all output in ${RUN_DIR}"
log "============================================================"
