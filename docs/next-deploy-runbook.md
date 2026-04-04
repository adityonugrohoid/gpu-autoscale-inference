# Next Deploy Runbook — Full-Cycle Demo with Complete Evidence Capture

Goal: deploy, run full-cycle, capture synced Grafana screenshot (12 panels) + raw event logs, then tear down.

## Pre-requisites

- [ ] gcloud CLI authenticated: `gcloud config configurations activate gcp-lab`
- [ ] GCP credits remaining: check at https://console.cloud.google.com/billing
- [ ] Secondary boot disk image exists: `gcloud compute images describe vllm-node-cache-20260405 --project=project-15693e31-5f7e-4fce-b55`
- [ ] AR images exist: `gcloud artifacts docker images list us-docker.pkg.dev/project-15693e31-5f7e-4fce-b55/llm-gateway`

If AR images or disk image are missing, rebuild:
```bash
# Rebuild AR images (gateway + worker + vllm) via Cloud Build
gcloud builds submit ./gateway --tag us-docker.pkg.dev/project-15693e31-5f7e-4fce-b55/llm-gateway/gateway:latest --project project-15693e31-5f7e-4fce-b55 --quiet
gcloud builds submit ./worker --tag us-docker.pkg.dev/project-15693e31-5f7e-4fce-b55/llm-gateway/worker:latest --project project-15693e31-5f7e-4fce-b55 --quiet

# Rebuild secondary boot disk (~10 min)
./scripts/build-node-cache.sh
```

## Step 1 — Deploy (~10 min)

```bash
./scripts/deploy-gcp.sh
```

This creates:
- GKE cluster (1x e2-standard-2, us-east1-d)
- GPU node pool (n1-standard-4 + T4 Spot, 0-1 nodes, secondary boot disk)
- KEDA + kube-state-metrics
- All K8s manifests (gateway, redis, vllm, worker, prometheus, grafana, dcgm-exporter)
- Model init job (downloads Qwen2.5-1.5B to PVC)
- Sets AR images on deployments

## Step 2 — Verify zero state

```bash
K=$(gcloud info --format="value(installation.sdk_root)")/bin/kubectl

# Confirm no GPU node, no worker/vllm pods
$K get nodes
$K get pods -n llm-gateway

# Confirm gateway healthy
GATEWAY_IP=$($K get svc gateway -n llm-gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -s http://${GATEWAY_IP}/health
# Expected: {"status":"ok"}

# Confirm KEDA scaled objects ready
$K get scaledobjects -n llm-gateway
# Expected: READY=True, ACTIVE=False for both
```

## Step 3 — Verify Grafana dashboard has 12 panels

```bash
$K port-forward svc/grafana 3000:3000 -n llm-gateway &

# Open http://localhost:3000 in browser
# Dashboard: LLM Gateway
# Verify 12 panels in 4x3 grid:
#   Row 1: Queue Depth | Worker Pod Count | Node Count | GPU Utilization
#   Row 2: vLLM Running Requests | vLLM Waiting Requests | KV Cache Usage | GPU Power Draw
#   Row 3: Tokens/sec | Request Latency (p50/p95) | TTFT | GPU Memory Used
```

## Step 4 — Run full-cycle (~15 min)

```bash
./scripts/full-cycle-run.sh ${GATEWAY_IP}
```

This runs 4 phases automatically:
1. **Phase 1 — Cold Start**: fires 30 requests, waits for GPU node + vLLM + inference completion
2. **Valley Gap**: 60s pause to create visible gap in metrics
3. **Phase 2 — Warm Response**: fires 100 requests into warm system
4. **Cool Down**: waits for KEDA to scale pods to 0, then GPU node removal

Output: `data/run-YYYYMMDD-HHMMSS/` with 10 log files.

**Do NOT proceed to Step 5 until the script prints `COOL DOWN COMPLETE — full zero state`.**

## Step 5 — Capture Grafana screenshot (within 5 min of run completion)

The screenshot must be captured **after** full zero state but **before** Prometheus expires the data (24h retention, but render while fresh for sharpest resolution).

### Option A — Automated capture via Grafana render API

```bash
# Get the run timestamps from timeline.log
RUN_DIR=$(ls -td data/run-* | head -1)
START=$(head -1 ${RUN_DIR}/timeline.log | awk -F'|' '{print $2}' | xargs)
END=$(tail -1 ${RUN_DIR}/timeline.log | awk -F'|' '{print $2}' | xargs)

echo "Run window: ${START} to ${END}"

# Add 60s buffer before start, 120s buffer after end
FROM_ISO=$(python3 -c "from datetime import datetime, timedelta; t=datetime.fromisoformat('${START}'.replace('Z','+00:00')); print((t - timedelta(seconds=60)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
TO_ISO=$(python3 -c "from datetime import datetime, timedelta; t=datetime.fromisoformat('${END}'.replace('Z','+00:00')); print((t + timedelta(seconds=120)).strftime('%Y-%m-%dT%H:%M:%SZ'))")

# Convert to epoch ms for Grafana
FROM_MS=$(python3 -c "from datetime import datetime; print(int(datetime.fromisoformat('${FROM_ISO}'.replace('Z','+00:00')).timestamp()*1000))")
TO_MS=$(python3 -c "from datetime import datetime; print(int(datetime.fromisoformat('${TO_ISO}'.replace('Z','+00:00')).timestamp()*1000))")

# Render via Grafana API (from inside the cluster)
$K exec -n llm-gateway deploy/grafana -c grafana -- \
  curl -s -o /tmp/dashboard.png \
  "http://localhost:3000/render/d/llm-gateway/llm-gateway?orgId=1&from=${FROM_MS}&to=${TO_MS}&width=1920&height=900&tz=UTC"

# Extract the PNG
$K exec -n llm-gateway deploy/grafana -c grafana -- cat /tmp/dashboard.png > docs/grafana-full-cycle.png

# Verify the screenshot
ls -la docs/grafana-full-cycle.png
# Should be >50KB. Open and verify:
#   - All 12 panels visible
#   - Queue depth shows hill → valley → spike → zero
#   - Node count shows GPU node appearing and disappearing
#   - GPU metrics (utilization, power, memory) show activity during inference
#   - Worker pod count shows 0→2→0 pattern
#   - Time range covers from pre-flight to post-zero-state
```

### Option B — Manual screenshot via browser

```bash
$K port-forward svc/grafana 3000:3000 -n llm-gateway &
```

1. Open http://localhost:3000/d/llm-gateway/llm-gateway
2. Set time range to cover the run window (from timeline.log timestamps) with 60s before / 120s after
3. Verify all 12 panels show data
4. Verify Node Count panel shows GPU nodes dropping to 0 at the right edge
5. Browser screenshot → save to `docs/grafana-full-cycle.png`

## Step 6 — Validate evidence completeness

```bash
RUN_DIR=$(ls -td data/run-* | head -1)

echo "=== Timeline ==="
cat ${RUN_DIR}/timeline.log

echo ""
echo "=== Verify scale-to-zero in logs ==="
grep "COOL DOWN COMPLETE" ${RUN_DIR}/timeline.log
grep "KEDAScaleTargetDeactivated" ${RUN_DIR}/k8s-events.log
tail -1 ${RUN_DIR}/pod-lifecycle.log
# Expected: vllm=0 | workers=0 | gpu_nodes=0

echo ""
echo "=== Verify Grafana screenshot ==="
ls -la docs/grafana-full-cycle.png
# Open and confirm 12 panels with data + zero state at right edge

echo ""
echo "=== Evidence checklist ==="
echo "[ ] timeline.log shows COOL DOWN COMPLETE"
echo "[ ] k8s-events.log shows KEDAScaleTargetDeactivated for vllm + worker"
echo "[ ] pod-lifecycle.log final line shows vllm=0, workers=0, gpu_nodes=0"
echo "[ ] keda-events.log shows Activated + Deactivated pairs"
echo "[ ] redis-queue.log shows queue=30 → queue=0 → queue=100 → queue=0"
echo "[ ] Grafana screenshot shows 12 panels with data"
echo "[ ] Grafana screenshot shows GPU node count at 0 at right edge"
echo "[ ] worker-output.log shows Processing/Completed job messages"
echo "[ ] vllm-output.log shows model load + inference activity"
```

## Step 7 — Commit and push

```bash
git checkout -b docs/full-cycle-evidence-v2
git add docs/grafana-full-cycle.png monitoring/prometheus.yaml
git commit -m "docs: 12-panel Grafana dashboard + synced full-cycle screenshot"
git push -u origin docs/full-cycle-evidence-v2
gh pr create --title "docs: 12-panel dashboard with complete evidence capture" --body "..."
gh pr merge --merge
git checkout main && git pull
git branch -d docs/full-cycle-evidence-v2
git push origin --delete docs/full-cycle-evidence-v2
```

## Step 8 — Tear down

```bash
./scripts/destroy-gcp.sh
```

Preserved assets (~$0.10/day):
- Disk image: `vllm-node-cache-20260405` (~$2.50/mo)
- AR images: gateway + worker + vllm (~$0.50/mo)
- GCS bucket: node-cache-logs (~$0.01/mo)

## Timing Estimate

| Step | Duration |
|---|---|
| Deploy | ~10 min |
| Verify + Grafana check | ~2 min |
| Full-cycle run | ~15 min (5.6 min cold start + 1 min valley + 20s warm + ~8 min cool down) |
| Screenshot capture | ~2 min |
| Validate + commit | ~3 min |
| Tear down | ~5 min |
| **Total** | **~37 min** |

## Cost Estimate

| Phase | Duration | Rate | Cost |
|---|---|---|---|
| Cluster idle (deploy + verify) | ~12 min | $0.18/hr | ~$0.04 |
| GPU active (cold start + warm) | ~6 min | $0.29/hr | ~$0.03 |
| Cool down + screenshot | ~10 min | $0.18/hr | ~$0.03 |
| Tear down | ~5 min | $0.18/hr | ~$0.02 |
| **Total** | **~33 min** | | **~$0.12** |
