# gpu-autoscale-inference

## Overview

Portfolio project demonstrating production-grade AI infrastructure engineering: a scale-to-zero GPU inference platform built on Kubernetes. GPU nodes provision on demand when requests arrive and deprovision when idle, so the GPU tier costs $0 when the system is not in use.

This project targets roles: **ML Platform Engineer, AI Infrastructure Engineer, LLM Systems Engineer**.

## The Core Concept

LLM infrastructure faces a hard tradeoff: GPUs must stay active for low latency, but should shut down when idle to minimize cost. This project solves it with two layers of autoscaling:

- **KEDA (pod autoscaler):** watches Redis queue depth, scales Worker (0 to 2) and vLLM (0 to 1) pods
- **Cluster Autoscaler (node autoscaler):** sees the pending GPU pod, provisions or deprovisions the GPU VM

Result: no requests, no pods, no GPU node, $0/hr for the GPU tier.

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
 |
 v
API Gateway (FastAPI)  ->  POST /generate  ->  enqueue job  ->  return {job_id}
                                                  |
                                             Redis Queue
                                                  |
                              KEDA monitors queue depth (threshold: 5)
                                                  |
                               queue > 5: scale up Worker (0 to 2) + vLLM (0 to 1)
                                                  |
                              [cloud] Cluster Autoscaler provisions GPU node
                                                  |
                              vLLM loads Qwen2.5-1.5B from the PVC (about 2.5 min on T4)
                              readiness probe passes
                                                  |
                              Worker pulls job, POSTs to vLLM, writes result
                                                  |
                              Client polls GET /result/{job_id}
                                                  |
                              Queue drains, KEDA scales to 0
                              [cloud] Cluster Autoscaler removes GPU node
```

## Cluster Layout

```
KUBERNETES CLUSTER
├── Node A: CPU VM (always-on, cheap)
│   ├── Pod: gateway
│   ├── Pod: Redis
│   ├── Pod: KEDA
│   └── Pod: Cluster Autoscaler
│
└── Node B: GPU VM (provisions/deprovisions on demand)
    ├── Pod: vLLM        (KEDA scales, uses nvidia.com/gpu: 1)
    └── Pod: worker      (KEDA scales, calls vLLM over HTTP)
```

## API Contract

| Endpoint | Method | Response |
|---|---|---|
| `/generate` | POST (JSON body: `{prompt: str}`) | `{status: "queued", job_id: "..."}` |
| `/result/{job_id}` | GET | `{status: "pending"}` or `{status: "done", response: "..."}` or `{status: "error", message: "..."}` |
| `/health` | GET | `{status: "ok"}` |

All requests are fully async: `/generate` always returns a `job_id` and never blocks for inference.

## KEDA Scaling Rules

- Worker: `minReplicaCount: 0`, `maxReplicaCount: 2`, trigger: `inference_queue` length > 5
- vLLM: `minReplicaCount: 0`, `maxReplicaCount: 1`, same trigger
- Ratio: 2 workers share 1 vLLM instance via HTTP (vLLM handles concurrency via continuous batching)

## Key Implementation Details

- `job_queue.py`: Redis helpers (NOT `queue.py`, which collides with the Python stdlib)
- `VLLM_URL`: worker env var. The manifest sets `http://vllm:8000`; `scripts/deploy-local.sh` overrides it to `http://host.docker.internal:8000` with `kubectl set env`
- `MODEL_ID`: env var in worker + vLLM deployment: `Qwen/Qwen2.5-1.5B-Instruct` (model-agnostic, swappable)
- `wait_for_vllm()` in worker: retry loop on the `/health` endpoint, handles model load delay
- Result store TTL: 5 minutes. Failed jobs write `{status: error}`, never leave the key empty
- vLLM readiness probe: `httpGet /health`, `initialDelaySeconds: 10`, `periodSeconds: 5`, `failureThreshold: 60` (5 min ceiling; observed model load about 142 s)

## Deployment Targets

### Local GPU (k3d)

vLLM runs on the **host in Docker** (not inside k3d). Everything else runs inside k3d.

```bash
# Start vLLM on host (uses local 8GB GPU)
docker run --gpus all -p 8000:8000 --ipc=host \
  vllm/vllm-openai --model Qwen/Qwen2.5-1.5B-Instruct \
  --max-model-len 4096 --gpu-memory-utilization 0.8 --enforce-eager

# Create k3d cluster, build and import images, install KEDA, apply manifests,
# point the worker at the host vLLM, deploy monitoring
./scripts/deploy-local.sh

# Run load test
source .venv/bin/activate
locust -f loadtest/locustfile.py --host http://localhost:8080

# Tear down
./scripts/destroy-local.sh
```

Local does NOT demonstrate node-level autoscaling (the GPU is always physically present).
Local Grafana shows empty GPU and vLLM panels: dcgm-exporter needs a GPU node in K8s, and Prometheus scrapes vLLM at the in-cluster `vllm:8000` Service.

### Cloud GPU (GCP GKE)

Same manifests; `scripts/deploy-gcp.sh` applies `k8s/`, then the GPU patch from `k8s-cloud/gcp/`.

- GKE Standard, zone `us-east1-d`, GPU: NVIDIA T4 Spot (`n1-standard-4`), Secondary Boot Disk: `vllm-node-cache-20260405`
- The GCP scripts read the project id from `GCP_PROJECT`
- One-time prereq: `gcloud services enable container.googleapis.com`

```bash
export GCP_PROJECT=<your-gcp-project-id>

# Create GKE cluster + GPU node pool, push images, apply manifests and the GPU patch
./scripts/deploy-gcp.sh

# Verify GPU node scaling
kubectl get nodes -w

# Run load test against LoadBalancer IP
GATEWAY_IP=$(kubectl get svc gateway -n llm-gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
locust -f loadtest/locustfile.py --host http://$GATEWAY_IP

# ALWAYS tear down after session (control plane ~$0.10/hr + GPU spot ~$0.11/hr while running)
./scripts/destroy-gcp.sh
```

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

# Full-cycle demo run with raw event logging (writes data/run-YYYYMMDD-HHMMSS/)
./scripts/full-cycle-run.sh [GATEWAY_IP]
```

## Project Structure

```
gpu-autoscale-inference/
├── gateway/
│   ├── main.py                      # FastAPI: /generate + /result + /health
│   ├── job_queue.py                 # Redis enqueue + result store
│   ├── Dockerfile
│   └── requirements.txt
├── worker/
│   ├── worker.py                    # Queue consumer, calls vLLM, writes results
│   ├── Dockerfile
│   └── requirements.txt
├── k8s/                             # Cloud-agnostic manifests
│   ├── namespace.yaml
│   ├── redis.yaml                   # Redis + redis-exporter
│   ├── gateway-deployment.yaml
│   ├── gateway-service.yaml         # LoadBalancer (cloud) / NodePort (local)
│   ├── vllm-deployment.yaml         # replicas: 0, readinessProbe, PVC mount
│   ├── vllm-service.yaml            # ClusterIP
│   ├── vllm-pvc.yaml                # 10 GB PVC for model weights
│   ├── vllm-model-init-job.yaml     # one-time snapshot_download to the PVC
│   ├── vllm-keda-scaledobject.yaml  # max: 1
│   ├── worker-deployment.yaml       # replicas: 0
│   └── worker-keda-scaledobject.yaml # max: 2
├── k8s-cloud/
│   └── gcp/
│       └── vllm-gpu-patch.yaml      # GPU tolerations + nodeSelector for vLLM
├── monitoring/
│   ├── prometheus.yaml              # Prometheus + Grafana; the 12-panel dashboard is the grafana-dashboards ConfigMap
│   └── dcgm-exporter.yaml
├── loadtest/
│   └── locustfile.py                # POST /generate + poll /result until done
├── scripts/
│   ├── deploy-local.sh
│   ├── deploy-gcp.sh
│   ├── destroy-local.sh
│   ├── destroy-gcp.sh
│   ├── build-node-cache.sh          # GKE secondary boot disk image
│   └── full-cycle-run.sh            # Full scale-to-zero demo with raw event logging
├── docs/
│   ├── cold-start-optimization.md   # Research, plan and results
│   └── *.png                        # Grafana screenshots from run-20260406-190041
├── data/                            # Runtime artifacts, gitignored
│   └── run-YYYYMMDD-HHMMSS/         # Per-run log files (events, KEDA, Redis, timeline...)
├── .env.example
└── README.md
```

## Observability Metrics

What the deployed Grafana dashboard (ConfigMap in `monitoring/prometheus.yaml`) can show on each target:

| Metric | Local (k3d) | GKE |
|---|---|---|
| Queue depth vs KEDA threshold | yes | yes |
| HPA/KEDA observed metric vs target | yes | yes |
| Worker + vLLM replica count | yes | yes |
| Total vs GPU node count | CPU node only | yes |
| vLLM request rate, prompt and generation tok/s | no | yes |
| TTFT p95 | no | yes |
| GPU SM util, power, HBM, temperature (DCGM) | no | yes |

## Key Decisions (Do Not Revisit Without Good Reason)

- **All requests async**: no inline sync path; `/generate` always returns `job_id`
- **No KServe**: plain K8s Deployment + Service is sufficient; KServe adds Istio/Knative complexity
- **No Ollama**: single vLLM runtime; consistent API surface, stronger portfolio signal
- **Qwen2.5-1.5B** (`Qwen/Qwen2.5-1.5B-Instruct`): small footprint (~3.5GB VRAM), ungated. Platform is model-agnostic via `MODEL_ID` env var. **vLLM startup flags for 8GB VRAM:** `--max-model-len 4096 --gpu-memory-utilization 0.8 --enforce-eager`
- **2 workers : 1 vLLM**: workers share vLLM over HTTP; vLLM handles concurrency natively
- **Locust load tuning**: Qwen2.5-1.5B is fast (~50 tok/s aggregate generation on T4), so use 100+ concurrent users with long prompts to keep the queue populated long enough for scaling to be visible in the demo
- **`job_queue.py` not `queue.py`**: avoids Python stdlib name collision

## Cold Start Optimization (implemented)

**Result:** Cold start went from **about 11 min** to **about 5.6 min** on T4 Spot, us-east1-d, 2026-04-05. Both totals were read from the Prometheus timeline; neither is a committed log line. The closest recorded run, run-20260405-015400, shows first completions at T+305 s and all samples complete at T+323 s; the baseline has no run directory.
Full research, breakdown, and L4 historical context: `docs/cold-start-optimization.md`

### Component 1: PV for model weights (done)
- Removed `vllm-custom/Dockerfile` (no more model baking)
- vLLM image reverted to stock `vllm/vllm-openai` (~8GB, unmodified)
- `k8s/vllm-pvc.yaml`: 10GB PVC for model weights
- `k8s/vllm-model-init-job.yaml`: one-time Job, `snapshot_download` to the PVC
- `k8s/vllm-deployment.yaml` mounts the PVC at `/root/.cache/huggingface`
- PVC survives pod restarts and node deletion (GCP Persistent Disk)
- **Independent contribution: ~1.5 min savings** (estimated; never measured in isolation). Main role is structural: it makes a stock 8 GB image cacheable on the secondary boot disk.

### Component 2: GKE Secondary Boot Disk (done)
- Officially supported GKE feature
- GCE disk image `vllm-node-cache-20260405` (50 GB, us-east1-d): vLLM layers pre-extracted into containerd's store
- GPU nodes boot with the disk attached, so there is no network image pull (observed image load ~7 s)
- Tool: `github.com/ai-on-gke/tools/tree/main/gke-disk-image-builder`, built via `scripts/build-node-cache.sh`
- Node pool flag: `--enable-image-streaming --secondary-boot-disk=disk-image=global/images/vllm-node-cache-20260405,mode=CONTAINER_IMAGE_CACHE`
- **Why not Image Streaming alone:** lazy remote IO kills Python/CUDA imports (tried, reverted). Secondary boot disk uses the same plugin but reads from local pd-ssd at full speed.
- `--enable-image-streaming` flag is **required** to unlock secondary boot disk, even though streaming itself hurts.
- Confirmed compatible with Spot nodes: each new Spot node gets a fresh PD clone.
- Caveat: a vLLM version change means rebuilding the disk image and recreating the node pool.

### Cold start benchmarks (T4 Spot, us-east1-d, 2026-04-05)
```
Baseline (11 GB baked image):        ~11 min    Prometheus timeline, no run directory
After PV only (8 GB image):          ~10 min    estimated, never run in isolation
After PV + Secondary Boot Disk:      ~5.6 min   Prometheus timeline (closest log: run-20260405-015400)
```

Remaining 5.6 min breakdown: ~2.5 min GPU node + driver init, ~7 s image load from the boot disk, ~2.5 min PVC to VRAM model load. Cannot easily go lower without abandoning scale-to-zero.

Earlier L4 baseline (us-central1-a, before hardware switch): ~9-9.5 min on `g2-standard-4 + L4`. Only the L4 run 23:50 has a Prometheus-confirmed breakdown; see `docs/cold-start-optimization.md`. No L4 run was ever measured with the optimizations applied.

## Out of Scope (Do Not Build Now)

- SSE token streaming
- Model multiplexing (Ollama-based hot-swap)
- AWS EKS + Karpenter

## Related Project

`vllm-explorer` (a separate repo) was used to explore vLLM endpoints and benchmark models before building this. Its `data/catalog.json` is the model selection reference.
