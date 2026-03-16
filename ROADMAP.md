# gpu-autoscale-inference Roadmap

## v0.1 Phase 1 — Local GPU Prototype (active)

**Goal:** full end-to-end request flow working locally with real inference. All K8s manifests finalized and tested on k3d.

- [ ] `gateway/main.py` — FastAPI: POST /generate + GET /result/{job_id} + GET /health
- [ ] `gateway/job_queue.py` — Redis enqueue + result store helpers (TTL 5min, error result on failure)
- [ ] `worker/worker.py` — blocking queue consumer, VLLM_URL from env, wait_for_vllm(), writes results
- [ ] `k8s/namespace.yaml`
- [ ] `k8s/redis.yaml`
- [ ] `k8s/gateway-deployment.yaml` + `k8s/gateway-service.yaml` (NodePort for local)
- [ ] `k8s/vllm-deployment.yaml` (replicas: 0, readinessProbe) + `k8s/vllm-service.yaml` (ClusterIP)
- [ ] `k8s/worker-deployment.yaml` (replicas: 0)
- [ ] `k8s/vllm-keda-scaledobject.yaml` (max: 1, queue threshold: 5)
- [ ] `k8s/worker-keda-scaledobject.yaml` (max: 2, queue threshold: 5)
- [ ] `monitoring/prometheus.yaml` + `monitoring/grafana-dashboard.json`
- [ ] `loadtest/locustfile.py` — POST /generate + poll /result until done (100+ users, long prompts — Qwen2.5-1.5B drains fast)
- [ ] `scripts/deploy-local.sh` + `scripts/destroy-local.sh`
- [ ] Verify KEDA pod scaling 0→1→0 under Locust load on k3d
- [ ] Grafana showing queue depth, latency, tokens/sec, pod count

---

## v0.1 Phase 2 — Cloud GPU Deployment (after Phase 1 complete)

**Goal:** full two-layer autoscaling demo (KEDA pods + Cluster Autoscaler nodes). Portfolio-grade demo recording.

**Primary platform: Azure AKS** (credits available). Switch to GCP GKE if credits land first.

- [ ] `k8s-cloud/azure/nodepool.yaml` — NC4as_T4_v3 GPU node pool, Cluster Autoscaler annotations
- [ ] `k8s-cloud/azure/gpu-tolerations-patch.yaml`
- [ ] `k8s-cloud/gcp/nodepool.yaml` — n1-standard-4 + T4, Cluster Autoscaler config
- [ ] `k8s-cloud/gcp/gpu-tolerations-patch.yaml`
- [ ] `scripts/deploy-azure.sh` + `scripts/destroy-azure.sh`
- [ ] `scripts/deploy-gcp.sh` + `scripts/destroy-gcp.sh`
- [ ] `gateway-service.yaml` updated to LoadBalancer type for cloud
- [ ] dcgm-exporter deployed — GPU utilization, TTFT active in Grafana
- [ ] Demo recording: idle (0 pods, 0 GPU nodes) → Locust (100+ users, long prompts) → node provisions → inference → scale-to-zero (~6–8 min cycle with Qwen2.5-1.5B)
- [ ] `README.md` — architecture diagram (mermaid) + demo GIF/video embed

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
