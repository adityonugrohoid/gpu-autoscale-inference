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
- [Demo](#demo)
- [Cold Start Optimization](#cold-start-optimization)
- [Observability](#observability)
- [Project Structure](#project-structure)
- [Roadmap](#roadmap)
- [Author](#author)

## Overview

This project demonstrates production-grade AI infrastructure: an LLM inference platform with fully elastic GPU provisioning. Requests are queued in Redis; when queue depth crosses a threshold, KEDA triggers event-driven pod autoscaling from zero replicas. On GKE, the Cluster Autoscaler provisions a GPU node in response to pending pods with `nvidia.com/gpu` resource requests — achieving true scale-to-zero at both the pod and node level.

vLLM serves inference using continuous batching, with model weights persisted on a PersistentVolumeClaim and container image layers pre-cached via GKE Secondary Boot Disk — reducing cold start from ~9 minutes to ~5 minutes.

## Features

- **Scale-to-zero GPU nodes** — Cluster Autoscaler provisions/deprovisions GPU VMs based on pending pod scheduling; $0/hr when idle
- **Event-driven pod autoscaling** — KEDA ScaledObjects watch Redis queue depth, scaling worker and vLLM Deployments between 0 and N replicas
- **Queue-buffered inference** — Redis absorbs request bursts during cold start; no dropped traffic, no client-side retry needed
- **Continuous batching** — vLLM batches concurrent requests at the attention layer, maximizing GPU throughput per dollar
- **Cold start optimization** — model weights on PVC (survives pod churn) + container image layer caching via GKE Secondary Boot Disk
- **GPU telemetry** — NVIDIA DCGM exporter for utilization, power draw, and VRAM; vLLM Prometheus exporter for KV cache, TTFT, and throughput; kube-state-metrics for pod/node lifecycle

## Tech Stack

| Layer | Tool | Role |
|---|---|---|
| API Gateway | FastAPI | Async request ingestion, job ID issuance |
| Message Queue | Redis (+ redis-exporter) | Job buffering, result store (5 min TTL) |
| Pod Autoscaler | KEDA ScaledObject | Event-driven 0↔N scaling on queue depth |
| Node Autoscaler | GKE Cluster Autoscaler | GPU VM provisioning on pending pod |
| Inference Engine | vLLM (OpenAI-compatible) | Continuous batching, KV cache, Prometheus metrics |
| Model | Qwen/Qwen2.5-1.5B-Instruct | 3.5 GB VRAM, ~100 tok/s on L4 |
| GPU Telemetry | NVIDIA DCGM exporter | GPU utilization, power, memory via Prometheus |
| Cluster Metrics | kube-state-metrics | Pod replica counts, node capacity, deployment state |
| Dashboarding | Grafana (12 panels) | Queue depth, GPU util, TTFT, tokens/sec, node count |
| Load Testing | Locust | Concurrent prompt injection for scaling validation |

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

### Autoscaling Layers

| Layer | Mechanism | Trigger | Scales | Latency |
|---|---|---|---|---|
| Pod | KEDA ScaledObject → HPA | `redis_key_size{key="inference_queue"}` > 5 | Worker Deployment 0↔2, vLLM Deployment 0↔1 | ~30s (KEDA polling) |
| Node | GKE Cluster Autoscaler | Pending pod with `nvidia.com/gpu: 1` resource request | GPU VM (g2-standard-4, L4) 0↔1 | ~2 min (GCE instance boot) |
| Image | GKE Secondary Boot Disk | Node boot event | Container layer cache attached as local pd-ssd | ~0s (pre-attached) |
| Model | PersistentVolumeClaim | vLLM pod start | Qwen2.5-1.5B weights at `/root/.cache/huggingface` | ~128s (VRAM load) |

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
Queue depth > 5 (KEDA ScaledObject trigger)
→ KEDA scales Worker Deployment 0→2, vLLM Deployment 0→1
→ vLLM pod enters Pending: requests nvidia.com/gpu: 1
→ Cluster Autoscaler provisions g2-standard-4 + L4 (spot, ~$0.15/hr)
→ GPU node boots with container image pre-cached (Secondary Boot Disk)
→ vLLM loads model weights from PVC into VRAM (3.5 GB, ~128s)
→ Readiness probe (httpGet /health, failureThreshold: 60) passes
→ Workers pull jobs via BRPOP, POST to vLLM /v1/completions
→ Results written to Redis (result:{job_id}, TTL 300s)
→ Queue drains → KEDA cooldown (300s) → pods scale to 0
→ Cluster Autoscaler: node unneeded 10 min → GPU VM deleted
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

## Cold Start Optimization

Cold start is the dominant cost in scale-to-zero GPU inference. The baseline path (vLLM baked into a custom 11 GB image) took ~9 minutes — most of it spent pulling the container image over the network to a freshly provisioned GPU node.

### The problem breakdown (baseline, 11 GB baked image)

| Phase | Duration | Bottleneck |
|---|---|---|
| GPU node provision (GCE boot) | ~30s | GCE API |
| Container image pull (11 GB) | ~8m20s | Network I/O to containerd |
| Model load to VRAM (3.5 GB) | ~30s | PCIe bandwidth |
| **Total** | **~9m20s** | |

### Two-component fix

**1. PersistentVolumeClaim for model weights**
- Separates 3.5 GB model from the vLLM base image (11 GB → 8 GB)
- One-time `snapshot_download` Job writes weights to a 10 Gi PVC
- PVC survives pod restarts and node deletion (GCE Persistent Disk)
- vLLM mounts at `/root/.cache/huggingface` via `HF_HOME` env var

**2. GKE Secondary Boot Disk for container image caching**
- Pre-extracts vLLM image layers into a GCE disk image
- GPU nodes boot with disk attached — containerd reads layers locally
- Eliminates network pull entirely ("seconds, regardless of image size")
- Built with `gke-disk-image-builder` from `github.com/ai-on-gke/tools`

### Result

| Phase | Baseline | After optimization |
|---|---|---|
| GPU node provision | ~30s | ~30s |
| Container image pull | ~8m20s | **~0s** (local disk) |
| Model load to VRAM | ~30s | **~128s** (PVC, cold read) |
| **Total** | **~9m20s** | **~5m9s** |

The remaining ~5 min is dominated by GCE node boot + NVIDIA driver initialization + PVC-to-VRAM transfer. Further reduction requires GPU-aware node pooling or persistent GPU reservation (out of scope for scale-to-zero).

## Observability

Four Prometheus exporters feed a 12-panel Grafana dashboard:

| Exporter | Endpoint | Key Metrics |
|---|---|---|
| redis-exporter | `:9121` | `redis_key_size{key="inference_queue"}` — queue depth |
| DCGM exporter | `:9400` | `DCGM_FI_DEV_GPU_UTIL`, `DCGM_FI_DEV_POWER_USAGE`, `DCGM_FI_DEV_FB_USED` |
| vLLM (built-in) | `:8000` | `vllm:num_requests_running`, `vllm:kv_cache_usage_perc`, `vllm:generation_tokens_total`, `vllm:time_to_first_token_seconds_bucket` |
| kube-state-metrics | `:8080` | `kube_deployment_status_replicas`, `kube_node_status_capacity{resource="nvidia_com_gpu"}` |

Scrape interval: 15s. Retention: 24h. No persistent storage (acceptable for demo; production would use Thanos or Grafana Cloud remote write).

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
