# gpu-autoscale-inference Roadmap

## v0.1 Phase 1 — Local GPU Prototype (complete)

**Goal:** full end-to-end request flow working locally with real inference. All K8s manifests finalized and tested on k3d.

- [x] `gateway/main.py` — FastAPI: POST /generate + GET /result/{job_id} + GET /health
- [x] `gateway/job_queue.py` — Redis enqueue + result store helpers (TTL 5min, error result on failure)
- [x] `worker/worker.py` — blocking queue consumer, VLLM_URL from env, wait_for_vllm(), writes results
- [x] `k8s/namespace.yaml`
- [x] `k8s/redis.yaml`
- [x] `k8s/gateway-deployment.yaml` + `k8s/gateway-service.yaml` (LoadBalancer)
- [x] `k8s/vllm-deployment.yaml` (replicas: 0, readinessProbe) + `k8s/vllm-service.yaml` (ClusterIP)
- [x] `k8s/worker-deployment.yaml` (replicas: 0)
- [x] `k8s/vllm-keda-scaledobject.yaml` (max: 1, queue threshold: 5)
- [x] `k8s/worker-keda-scaledobject.yaml` (max: 2, queue threshold: 5)
- [x] `monitoring/prometheus.yaml` + `monitoring/grafana-dashboard.json`
- [x] `loadtest/locustfile.py` — POST /generate + poll /result until done (100+ users, long prompts — Qwen2.5-1.5B drains fast)
- [x] `scripts/deploy-local.sh` + `scripts/destroy-local.sh`
- [x] Verify KEDA pod scaling 0→1→0 under Locust load on k3d
- [x] Grafana showing queue depth, latency, tokens/sec, pod count

---

## v0.1 Phase 2 — Cloud GPU Deployment (active — GCP GKE)

**Goal:** full two-layer autoscaling demo (KEDA pods + Cluster Autoscaler nodes). Portfolio-grade demo recording.

**Primary platform: GCP GKE** (T4 + L4 quota approved, preemptible ~$0.15/hr).

- [x] `k8s-cloud/gcp/vllm-gpu-patch.yaml` — GPU tolerations + nodeSelector (strategic merge patch)
- [x] `scripts/deploy-gcp.sh` + `scripts/destroy-gcp.sh`
- [x] `gateway-service.yaml` updated to LoadBalancer type for cloud
- [x] `monitoring/dcgm-exporter.yaml` — GPU metrics DaemonSet on GPU nodes
- [x] Prometheus scrape jobs for dcgm-exporter + vLLM metrics
- [x] Grafana Node Count panel (total + GPU nodes)
- [ ] Demo recording: idle (0 pods, 0 GPU nodes) → Locust (100+ users, long prompts) → node provisions → inference → scale-to-zero (~6-8 min cycle with Qwen2.5-1.5B)
- [ ] `README.md` — demo GIF/video embed

---

## Model Selection

**Decided: `Qwen/Qwen2.5-1.5B-Instruct`** for both Phase 1 and Phase 2.
- ~3.5GB VRAM, ~3GB disk, ~5-10s cold start, ungated, Alibaba/Qwen — top-5 on open model leaderboards, well-known in ML engineering
- Platform is model-agnostic — `MODEL_ID` env var in worker + vLLM deployment
- Locust tuning: 100+ concurrent users with long prompts (Qwen2.5-1.5B processes fast, queue drains quickly)
- **vLLM startup flags for 8GB VRAM:** `--max-model-len 4096 --gpu-memory-utilization 0.8 --enforce-eager`

---

## v0.2 — Streaming + Multiplexing

- [ ] SSE token streaming — `/generate/stream` endpoint
- [ ] Model multiplexing exploration (Ollama-based hot-swap)
- [ ] AWS EKS + Karpenter (if GPU quota approved)
