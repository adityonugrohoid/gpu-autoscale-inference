# gpu-autoscale-inference

## Overview

Portfolio project demonstrating production-grade AI infrastructure engineering: a scale-to-zero GPU inference platform built on Kubernetes. GPU nodes provision on demand when requests arrive and deprovision when idle — cost is $0 when the system is not in use.

This project targets roles: **ML Platform Engineer, AI Infrastructure Engineer, LLM Systems Engineer**.

## The Core Concept

LLM infrastructure faces a hard tradeoff: GPUs must stay active for low latency, but should shut down when idle to minimize cost. This project solves it with two layers of autoscaling:

- **KEDA (pod autoscaler):** watches Redis queue depth → scales Worker + vLLM pods 0↔1
- **Cluster Autoscaler (node autoscaler):** sees pending GPU pod → provisions/deprovisions the GPU VM

Result: no requests → no pods → no GPU node → $0/hr.

## Tech Stack

| Layer | Tool |
|---|---|
| API Gateway | FastAPI |
| Request Queue + Result Store | Redis |
| Pod Autoscaler | KEDA |
| Node Autoscaler (cloud) | Cluster Autoscaler |
| Queue Consumer | custom Python worker |
| Inference Engine | vLLM (Qwen/Qwen2.5-1.5B-Instruct) |
| Orchestration | Kubernetes (raw Deployment + Service) |
| Observability | Prometheus + Grafana + NVIDIA dcgm-exporter |
| Load Testing | Locust |

## Architecture

```
User
 │
 ▼
API Gateway (FastAPI)  →  POST /generate  →  enqueue job  →  return {job_id}
                                                  │
                                             Redis Queue
                                                  │
                              KEDA monitors queue depth (threshold: 5)
                                                  │
                               queue > 5 → scale up Worker (0→1) + vLLM (0→1)
                                                  │
                              [cloud] Cluster Autoscaler provisions GPU node
                                                  │
                              vLLM loads Qwen2.5-1.5B (~5-10s)
                              readiness probe passes
                                                  │
                              Worker pulls job → POSTs to vLLM → writes result
                                                  │
                              Client polls GET /result/{job_id}
                                                  │
                              Queue drains → KEDA scales to 0
                              [cloud] Cluster Autoscaler removes GPU node
```

## Cluster Layout

```
KUBERNETES CLUSTER
├── Node A — CPU VM (always-on, cheap)
│   ├── Pod: gateway
│   ├── Pod: Redis
│   ├── Pod: KEDA
│   └── Pod: Cluster Autoscaler
│
└── Node B — GPU VM (provisions/deprovisions on demand)
    ├── Pod: vLLM        ← KEDA scales, uses nvidia.com/gpu: 1
    └── Pod: worker      ← KEDA scales, calls vLLM over HTTP
```

## API Contract

| Endpoint | Method | Response |
|---|---|---|
| `/generate` | POST (JSON body: `{prompt: str}`) | `{status: "queued", job_id: "..."}` |
| `/result/{job_id}` | GET | `{status: "pending"}` or `{status: "done", response: "..."}` or `{status: "error", message: "..."}` |
| `/health` | GET | `{status: "ok"}` |

All requests are fully async — `/generate` always returns a `job_id`, never blocks for inference.

## KEDA Scaling Rules

- Worker: `minReplicaCount: 0`, `maxReplicaCount: 2`, trigger: `inference_queue` length > 5
- vLLM: `minReplicaCount: 0`, `maxReplicaCount: 1`, same trigger
- Ratio: 2 workers share 1 vLLM instance via HTTP (vLLM handles concurrency via continuous batching)

## Key Implementation Details

- `job_queue.py` — Redis helpers (NOT `queue.py` — name collision with Python stdlib)
- `VLLM_URL` — environment variable in worker: `http://host.docker.internal:8000` (Phase 1) or `http://vllm:8000` (Phase 2)
- `MODEL_ID` — environment variable in worker + vLLM deployment: `Qwen/Qwen2.5-1.5B-Instruct` (model-agnostic, swappable)
- `wait_for_vllm()` in worker — retry loop on `/health` endpoint, handles model load delay
- Result store TTL: 5 minutes — failed jobs write `{status: error}`, never leave key empty
- vLLM readiness probe: `httpGet /health`, `initialDelaySeconds: 10`, `periodSeconds: 10`

## Development Phases

### Phase 1 — Local GPU (current starting point)

vLLM runs on the **host in Docker** (not inside k3d). Everything else runs inside k3d.

```bash
# Start vLLM on host (uses local 8GB GPU)
docker run --gpus all -p 8000:8000 --ipc=host \
  vllm/vllm-openai --model Qwen/Qwen2.5-1.5B-Instruct \
  --max-model-len 4096 --gpu-memory-utilization 0.8 --enforce-eager

# Start k3d cluster
k3d cluster create llm-gateway --port "8080:80@loadbalancer"

# Deploy everything except vLLM
kubectl apply -f k8s/

# Run load test
source .venv/bin/activate
locust -f loadtest/locustfile.py --host http://localhost:8080
```

Worker env var for Phase 1: `VLLM_URL=http://host.docker.internal:8000`

Phase 1 does NOT demonstrate node-level autoscaling (GPU is always physically present locally).
Phase 1 Grafana will show empty GPU utilization/TTFT panels — expected, dcgm-exporter needs GPU node in K8s.

### Phase 2 — Cloud GPU (portfolio demo)

Same manifests, different config. Apply cloud-specific patches from `k8s-cloud/`.

**Primary: GCP GKE Standard** (T4 + L4 quota already approved all regions, preemptible ~$0.15/hr)

- GCP project: `project-15693e31-5f7e-4fce-b55` (account: `adityonugrohogcp@gmail.com`, gcloud config: `gcp-lab`)
- Zone: `us-east1-d`, GPU: NVIDIA T4 Spot (`n1-standard-4`), Secondary Boot Disk: `vllm-node-cache-20260405`
- One-time prereq: `gcloud services enable container.googleapis.com`

```bash
# Create GKE cluster + GPU node pool
./scripts/deploy-gcp.sh

# Apply base manifests
kubectl apply -f k8s/

# Apply GCP GPU tolerations
kubectl apply -f k8s-cloud/gcp/

# Verify GPU node scaling
kubectl get nodes -w

# Run load test against LoadBalancer IP
GATEWAY_IP=$(kubectl get svc gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
locust -f loadtest/locustfile.py --host http://$GATEWAY_IP

# ALWAYS tear down after session (GKE control plane ~$0.10/hr)
./scripts/destroy-gcp.sh
```

**Alt: Azure AKS** (credits available, GPU quota auto-approved on new accounts, ~$0.52/hr)

```bash
./scripts/deploy-azure.sh
kubectl apply -f k8s/
kubectl apply -f k8s-cloud/azure/
# ... same flow
./scripts/destroy-azure.sh
```

**AWS EKS blocked** — GPU quota not approved (needs billing history). Revisit later.

## Commands

```bash
# Local setup
python3 -m venv .venv && source .venv/bin/activate
pip install -r gateway/requirements.txt
pip install -r worker/requirements.txt
cp .env.example .env

# Gateway (local dev, outside k3d)
cd gateway && uvicorn main:app --reload --port 8000

# Worker (local dev, outside k3d)
cd worker && VLLM_URL=http://localhost:8000 python worker.py

# k3d local cluster
k3d cluster create llm-gateway --port "8080:80@loadbalancer"
kubectl apply -f k8s/

# Tear down local cluster
k3d cluster delete llm-gateway
```

## Project Structure

```
gpu-autoscale-inference/
├── gateway/
│   ├── main.py                      # FastAPI: /generate + /result + /health
│   ├── job_queue.py                 # Redis enqueue + result store
│   └── requirements.txt
├── worker/
│   ├── worker.py                    # Queue consumer, calls vLLM, writes results
│   └── requirements.txt
├── k8s/                             # Cloud-agnostic manifests
│   ├── namespace.yaml
│   ├── redis.yaml
│   ├── gateway-deployment.yaml
│   ├── gateway-service.yaml         # LoadBalancer (cloud) / NodePort (local)
│   ├── vllm-deployment.yaml         # replicas: 0, readinessProbe
│   ├── vllm-service.yaml            # ClusterIP
│   ├── vllm-keda-scaledobject.yaml  # max: 1
│   ├── worker-deployment.yaml       # replicas: 0
│   └── worker-keda-scaledobject.yaml # max: 2
├── k8s-cloud/
│   ├── azure/                       # NC4as_T4_v3 node pool, GPU tolerations
│   └── gcp/                         # n1-standard-4 + T4 node pool, GPU tolerations
├── monitoring/
│   ├── prometheus.yaml
│   └── grafana-dashboard.json       # Phase 1: queue/pod metrics; Phase 2: + GPU metrics
├── loadtest/
│   └── locustfile.py                # POST /generate + poll /result until done
├── scripts/
│   ├── deploy-local.sh
│   ├── deploy-azure.sh
│   ├── deploy-gcp.sh
│   ├── destroy-local.sh
│   ├── destroy-azure.sh
│   ├── destroy-gcp.sh
│   ├── build-node-cache.sh         # GKE secondary boot disk (Phase 3)
│   └── full-cycle-run.sh           # Comprehensive demo with raw event logging
├── data/                            # Runtime artifacts — gitignored
│   └── run-YYYYMMDD-HHMMSS/        # Per-run: 10 log files (events, KEDA, Redis, timeline...)
├── .env.example
├── ROADMAP.md
└── README.md
```

## Observability Metrics

| Metric | Phase 1 | Phase 2 |
|---|---|---|
| Queue depth | ✅ | ✅ |
| Tokens/sec | ✅ | ✅ |
| Request latency (p50, p95) | ✅ | ✅ |
| Worker + vLLM pod count | ✅ | ✅ |
| GPU utilization | ❌ | ✅ (dcgm-exporter) |
| TTFT | ❌ | ✅ |
| Node count | ❌ | ✅ |

## Key Decisions (Do Not Revisit Without Good Reason)

- **All requests async** — no inline sync path; `/generate` always returns `job_id`
- **No KServe** — plain K8s Deployment + Service is sufficient; KServe adds Istio/Knative complexity
- **No Ollama** — single vLLM runtime; consistent API surface, stronger portfolio signal
- **Qwen2.5-1.5B** (`Qwen/Qwen2.5-1.5B-Instruct`) — small footprint (~3.5GB VRAM), cold start (~5-10s), ungated, Alibaba/Qwen — top-5 on open model leaderboards, well-known in ML engineering. Platform is model-agnostic via `MODEL_ID` env var. **vLLM startup flags for 8GB VRAM:** `--max-model-len 4096 --gpu-memory-utilization 0.8 --enforce-eager`
- **2 workers : 1 vLLM** — workers share vLLM over HTTP; vLLM handles concurrency natively
- **Locust load tuning** — Qwen2.5-1.5B is fast (~100+ tok/s), so use 100+ concurrent users with long prompts to keep queue populated long enough for scaling to be visible in demo
- **`job_queue.py` not `queue.py`** — avoids Python stdlib name collision

## Phase 3 — Cold Start Optimization (implemented)

**Result:** Cold start reduced from **659 s (11 min)** → **338 s (5.6 min)** — 48% improvement on T4 Spot, us-east1-d, measured 2026-04-05.
Full research, breakdown, and L4 historical context: `docs/cold-start-optimization.md`

### Component 1 — PV for Model Weights ✅
- Removed `vllm-custom/Dockerfile` (no more model baking)
- vLLM image reverted to `vllm/vllm-openai:latest` (~8GB, unmodified)
- `k8s/vllm-pvc.yaml` — 10GB PVC for model weights
- `k8s/vllm-model-init-job.yaml` — one-time Job: `snapshot_download` → PVC
- `k8s/vllm-deployment.yaml` mounts PVC at `/root/.cache/huggingface`
- PVC survives pod restarts and node deletion (GCP Persistent Disk)
- **Independent contribution: ~1.5 min savings** (estimated; never measured in isolation). Main role is structural — makes a stock 8 GB image cacheable on the secondary boot disk.

### Component 2 — GKE Secondary Boot Disk ✅
- Officially supported GKE feature (1.30.1+)
- GCE disk image `vllm-node-cache-20260405` (50 GB, us-east1-d) — vLLM layers pre-extracted into containerd's store
- GPU nodes boot with disk attached → no image pull needed
- Tool: `github.com/ai-on-gke/tools/tree/main/gke-disk-image-builder`, built via `scripts/build-node-cache.sh`
- Node pool flag: `--enable-image-streaming --secondary-boot-disk=disk-image=global/images/vllm-node-cache-20260405,mode=CONTAINER_IMAGE_CACHE`
- **Why not Image Streaming alone:** lazy remote IO kills Python/CUDA imports (tried, reverted). Secondary boot disk uses same plugin but reads from local pd-ssd — full speed.
- `--enable-image-streaming` flag is **required** to unlock secondary boot disk, even though streaming itself hurts.
- Confirmed compatible with Spot nodes — each preempted node gets a fresh PD clone.
- Caveat: vLLM version change → rebuild disk image → recreate node pool.

### Cold Start Benchmarks (T4 Spot, us-east1-d, 2026-04-05)
```
Baseline (11 GB baked image):        659 s (~11 min)  ✅ measured
After PV only (8 GB image):          ~10 min          ⚠ estimated, never run in isolation
After PV + Secondary Boot Disk:      338 s (~5.6 min) ✅ measured
```

Remaining 5.6 min breakdown: ~2.5 min GPU node + driver init, ~30 s container start (image local), ~2.5 min PVC → VRAM model load. Cannot easily go lower without abandoning scale-to-zero.

Earlier L4 baseline (us-central1-a, before hardware switch): ~9-9.5 min on `g2-standard-4 + L4`. Only the L4 run 23:50 has a Prometheus-confirmed breakdown — see `docs/cold-start-optimization.md`. No L4 run was ever measured with the optimizations applied.

## v0.2 Scope (Do Not Build Now)

- SSE token streaming
- Model multiplexing (Ollama-based hot-swap)
- AWS EKS + Karpenter (if GPU quota unblocked)

## Related Project

`~/projects/vllm-explorer` — used to explore vLLM endpoints and benchmark models before building this. Check `data/catalog.json` there for model selection reference.
