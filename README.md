<div align="center">

# gpu-autoscale-inference

[![Python 3.12+](https://img.shields.io/badge/python-3.12+-blue.svg)](https://www.python.org/downloads/)
[![Kubernetes](https://img.shields.io/badge/kubernetes-1.28+-blue.svg)](https://kubernetes.io/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Status](https://img.shields.io/badge/status-active-success.svg)](#)

**A scale-to-zero GPU inference platform — GPU nodes provision on demand, cost is $0 when idle.**

[Architecture](#architecture) | [Getting Started](#getting-started) | [Demo](#demo)

</div>

---

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Tech Stack](#tech-stack)
- [Architecture](#architecture)
- [Getting Started](#getting-started)
- [How It Works](#how-it-works)
- [Project Structure](#project-structure)
- [Roadmap](#roadmap)
- [Author](#author)

## Overview

This project demonstrates production-grade AI infrastructure engineering: an LLM inference platform where GPU resources are fully elastic. When request queue depth exceeds a threshold, KEDA scales worker pods from zero. In cloud deployment, a Cluster Autoscaler provisions the GPU virtual machine itself — so zero idle cost is not just pod-level but node-level.

The architecture mirrors inference platforms used by OpenAI, Anthropic, and Google — scaled down to a single GPU.

## Features

- **Scale-to-zero GPU** — GPU node provisions on demand, deprovisions when idle
- **Two-layer autoscaling** — KEDA (pod) + Cluster Autoscaler (node) working in tandem
- **Queue-driven inference** — Redis queue buffers requests during cold start; no dropped traffic
- **Async API** — fire-and-forget `/generate`, poll `/result/{job_id}`
- **Production observability** — Prometheus + Grafana + NVIDIA dcgm-exporter

## Tech Stack

| Layer | Tool |
|---|---|
| API Gateway | FastAPI |
| Queue + Result Store | Redis |
| Pod Autoscaler | KEDA |
| Node Autoscaler | Cluster Autoscaler (AKS / GKE) |
| Queue Consumer | Python worker |
| Inference Engine | vLLM + Qwen/Qwen2.5-1.5B-Instruct |
| Orchestration | Kubernetes |
| Observability | Prometheus + Grafana + dcgm-exporter |
| Load Testing | Locust |

## Architecture

```mermaid
graph TD
    U["User"] --> G["API Gateway\nFastAPI :8000"]
    G --> Q[("Redis Queue\ninference_queue")]
    Q --> K["KEDA\nqueue depth > 5"]
    K --> W["Worker pods\n0 → 1–2"]
    K --> V["vLLM pod\n0 → 1"]
    V --> CA["Cluster Autoscaler\nprovisions GPU node"]
    W --> V
    W --> R[("Redis Result Store\nresult:{job_id}")]
    R --> G

    style U fill:#0f3460,color:#fff
    style G fill:#533483,color:#fff
    style Q fill:#16213e,color:#fff
    style K fill:#533483,color:#fff
    style W fill:#0f3460,color:#fff
    style V fill:#533483,color:#fff
    style CA fill:#16213e,color:#fff
    style R fill:#16213e,color:#fff
```

### Two-Layer Autoscaling

| Layer | Tool | Trigger | What scales |
|---|---|---|---|
| Pod | KEDA | Redis queue depth > 5 | Worker + vLLM Deployments 0↔1 |
| Node | Cluster Autoscaler | Pending pod with GPU request | GPU VM 0↔1 |

## Getting Started

### Prerequisites

- Python 3.12+
- Docker with NVIDIA GPU support
- k3d (Phase 1 local) or cloud CLI: `az` / `gcloud` (Phase 2)
- kubectl, helm

### Phase 1 — Local

```bash
# 1. Start vLLM on host (uses local GPU directly)
docker run --gpus all -p 8000:8000 --ipc=host \
  vllm/vllm-openai --model Qwen/Qwen2.5-1.5B-Instruct \
  --max-model-len 4096 --gpu-memory-utilization 0.8 --enforce-eager

# 2. Create local k3d cluster
k3d cluster create llm-gateway --port "8080:80@loadbalancer"

# 3. Install KEDA
helm repo add kedacore https://kedacore.github.io/charts
helm install keda kedacore/keda --namespace keda --create-namespace

# 4. Deploy all manifests
kubectl apply -f k8s/

# 5. Run load test
source .venv/bin/activate
locust -f loadtest/locustfile.py --host http://localhost:8080
```

### Phase 2 — Cloud (GCP GKE)

```bash
# Deploy: creates GKE cluster, GPU node pool (T4 spot), pushes images, applies manifests
./scripts/deploy-gcp.sh

# Get gateway IP
GATEWAY_IP=$(kubectl get svc gateway -n llm-gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl http://$GATEWAY_IP/health

# Trigger scaling (6+ requests to exceed KEDA threshold)
for i in $(seq 1 6); do
  curl -s -X POST http://$GATEWAY_IP/generate \
    -H 'Content-Type: application/json' \
    -d '{"prompt":"Explain autoscaling"}' &
done

# Watch two-layer scaling
kubectl get nodes -w                    # GPU node appears (~2-4 min)
kubectl get pods -n llm-gateway -w      # vLLM + worker go Pending -> Running

# Load test
locust -f loadtest/locustfile.py --host http://$GATEWAY_IP

# Monitoring
kubectl port-forward svc/grafana 3000:3000 -n llm-gateway

# ALWAYS tear down after session (~$0.10/hr control plane + ~$0.15/hr GPU spot)
./scripts/destroy-gcp.sh
```

### Configuration

```bash
cp .env.example .env
```

<details>
<summary>Configuration reference</summary>

```bash
# Worker: vLLM server URL
# Phase 1 (host Docker): http://host.docker.internal:8000
# Phase 2 (K8s Service):  http://vllm:8000
VLLM_URL=http://host.docker.internal:8000

REDIS_HOST=redis
REDIS_PORT=6379
```

</details>

## How It Works

### 1. Request Flow

Every prompt is enqueued immediately. `/generate` always returns a `job_id`. No request blocks for inference.

### 2. Autoscaling Chain

```
Queue depth > 5
→ KEDA scales Worker (0→1) + vLLM (0→1)
→ vLLM pod requests nvidia.com/gpu: 1
→ [cloud] Cluster Autoscaler provisions GPU node
→ GPU node boots with vLLM image pre-cached (GKE Secondary Boot Disk)
→ vLLM loads model weights from PVC (~128s), readiness probe passes
→ Worker pulls jobs, calls vLLM, writes results
→ Queue drains → KEDA scales to 0 → GPU node removed
```

### 3. Result Retrieval

Poll `GET /result/{job_id}`. Returns `{status: pending}` until inference completes, then `{status: done, response: "..."}`. Results expire after 5 minutes.

## Demo

Full cycle run on GCP GKE (g2-standard-4, NVIDIA L4, us-central1-a).

![Grafana full-cycle dashboard](docs/grafana-full-cycle.png)

### What the dashboard shows

A hill, a valley, and a spike — each telling a different story:

**Phase 1 — Cold Start (left hill, ~5 min plateau)**
- Queue depth holds at 30 for ~5 minutes while the system cold-starts from zero
- GPU node provisions (+1m53s), vLLM image loads from secondary boot disk, model loads from PVC
- Worker pods scale 0→1→2, vLLM pod scales 0→1
- GPU memory jumps from 0 → 18 GB once model is in VRAM
- First tokens begin at ~5m9s; queue drains in seconds once vLLM is ready

**Valley — ~60s baseline**
- Queue at 0; GPU node and pods still warm (Cluster Autoscaler has not yet deprovisioned)

**Phase 2 — Warm Response (right spike, ~30s)**
- 100 requests fired into an already-warm system (GPU node up, vLLM loaded)
- Queue spikes and drains in ~30s — no cold start overhead, workers immediately consume jobs
- GPU utilization spikes sharply; TTFT ~140–200ms p95
- Tokens/sec peak visible in row 3

**Cool down**
- KEDA scales pods to 0 after ~5m32s of inactivity
- Cluster Autoscaler removes GPU node after ~17m15s — cost drops to $0

### Benchmark numbers (GCP GKE, NVIDIA L4)

| Metric | Value |
|---|---|
| Cold start (GPU node → first token) | **5m9s** |
| Warm response (100 jobs, no cold start) | **30s** |
| TTFT p95 | **~140–200ms** |
| Pods → 0 after idle | **~5m32s** (KEDA cooldown) |
| GPU node → 0 after idle | **~17m15s** (Cluster Autoscaler) |
| Cost when idle | **$0** |

## Project Structure

```
gpu-autoscale-inference/
├── gateway/                         # FastAPI gateway
├── worker/                          # Redis queue consumer
├── k8s/                             # Cloud-agnostic K8s manifests
├── k8s-cloud/azure/                 # AKS-specific node pool + GPU tolerations
├── k8s-cloud/gcp/                   # GKE-specific node pool + GPU tolerations
├── monitoring/                      # Prometheus + Grafana config
├── loadtest/                        # Locust load test
├── scripts/                         # Deploy + destroy scripts per environment
└── data/                            # Runtime artifacts (gitignored)
```

## Roadmap

See [ROADMAP.md](ROADMAP.md) for detailed version history and plans.

- [x] Repository scaffolded
- [x] v0.1 Phase 1 — Local GPU prototype (k3d)
- [x] v0.1 Phase 2 — Cloud GPU deployment (GCP GKE)
- [x] v0.1 Phase 3 — Cold start optimization (PV for model weights + GKE Secondary Boot Disk)
- [ ] v0.2 — SSE streaming, model multiplexing

## Author

**Adityo Nugroho** ([@adityonugrohoid](https://github.com/adityonugrohoid))

## Acknowledgments

- [vLLM](https://github.com/vllm-project/vllm) — high-throughput LLM inference engine
- [KEDA](https://keda.sh) — Kubernetes Event-driven Autoscaling
