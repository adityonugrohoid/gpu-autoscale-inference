# Cold Start Optimization — Research & Plan

## Problem

vLLM on GKE with scale-to-zero GPU nodes has a ~9 minute cold start:

```
30s  — Cluster Autoscaler provisions GPU VM (g2-standard-4 + L4)
6.5m — GPU node pulls 11GB Docker image from Artifact Registry (~28MB/s)
1.5m — vLLM starts Python/CUDA and loads model weights into VRAM
────
~9m  total from queue spike to first token
```

The 28MB/s pull speed is not network-bandwidth-limited (g2-standard-4 has 10Gbps). It is
limited by containerd's default layer-pull parallelism (3 concurrent layers) and CPU
decompression on a 4-vCPU node. No GKE config knob exposes `max_concurrent_downloads`.

---

## Why the Image Is 11GB (Current State)

The current `vllm-custom/Dockerfile` bakes the Qwen2.5-1.5B model weights into the image:

```
vllm/vllm-openai base:   ~8GB  (PyTorch + CUDA + vLLM)
Qwen2.5-1.5B weights:    ~3.5GB (baked in via snapshot_download)
────────────────────────────────
Total:                   ~11GB
```

This was intended to eliminate the 29s HuggingFace download at runtime. It was the wrong
tradeoff — adding 3.5GB to the pull cost (extra ~1.5 min) to save 29s. Net effect: cold
start got slightly slower.

---

## Approaches Evaluated

| Approach | Works for scale-to-zero? | Expected savings | Verdict |
|---|---|---|---|
| **PV for model weights** | Yes | 11GB → 8GB pull, ~1.5 min saved | ✅ Build |
| **GKE Secondary Boot Disk** | Yes — official GKE feature | 8GB pull → seconds | ✅ Build |
| eStargz / Stargz Snapshotter | No — GKE managed containerd blocks custom plugins | same as Image Streaming | ❌ |
| GKE Image Streaming (tried) | Worse — lazy remote IO kills Python/CUDA imports | negative | ❌ reverted |
| DaemonSet pre-pull | No — cache dies with node on scale-to-zero | zero | ❌ |
| Artifact Registry optimization | No knobs available | zero | ❌ |
| Docker layer splitting | No — cache dies with node on scale-to-zero | zero | ❌ |
| min-1 GPU node always-on | Eliminates cold start, $0.70/hr ongoing | portfolio tradeoff too weak | ❌ rejected |
| Switch to Ollama (GGUF) | Yes, ~2 min cold start | abandons vLLM portfolio signal | ❌ rejected |

---

## Chosen Plan: PV + Secondary Boot Disk

### Component 1 — PersistentVolume for Model Weights

Remove model baking from the vLLM image. Store Qwen2.5-1.5B weights on a GCP Persistent
Disk (PVC) that survives pod restarts and node deletion.

**What changes:**
- Delete `vllm-custom/Dockerfile` — no more custom build
- vLLM image reverts to `vllm/vllm-openai:latest` (~8GB, no model weights)
- Add `k8s/vllm-pvc.yaml` — 10GB PersistentVolumeClaim
- Add `k8s/vllm-model-init-job.yaml` — one-time Job that runs `snapshot_download` to
  populate the PVC on first deploy
- Patch `k8s/vllm-deployment.yaml` — mount PVC at `/root/.cache/huggingface`

**Flow:**
```
First deploy only:
  init Job → downloads Qwen2.5-1.5B (3.5GB from HuggingFace) → writes to PVC → done

Every cold start after:
  GPU node provisions → pulls 8GB vLLM image (~5 min)
  vLLM pod mounts PVC (weights already there) → loads model in ~30s
```

**PVC cost:** ~10GB GCP pd-standard = ~$0.17/month.

### Component 2 — GKE Secondary Boot Disk

A first-party GKE feature. Build a GCE disk image with the vLLM container layers
pre-extracted into containerd's image store. GPU nodes boot with this disk attached —
containerd finds the image already cached locally.

GKE docs: *"no more than a few seconds, regardless of image size."*

**Why this works where Image Streaming failed:**
- Image Streaming: container "starts" in 2s, but reads files lazily over the network
  during Python/CUDA import — thousands of remote reads = slow
- Secondary Boot Disk: uses the same `gcfs-snapshotter` plugin, but data comes from
  a locally attached pd-ssd — all reads are local disk I/O at full speed

**Build workflow:**
```bash
# Install gke-disk-image-builder
# https://github.com/ai-on-gke/tools/tree/main/gke-disk-image-builder

go run ./cli \
  --project-name=sonorous-reach-438808-c6 \
  --image-name=vllm-cache-v<VERSION> \
  --zone=us-central1-a \
  --gcs-path=gs://<LOG_BUCKET> \
  --disk-size-gb=20 \
  --container-image=us-docker.pkg.dev/sonorous-reach-438808-c6/llm-gateway/vllm-openai:latest \
  --image-pull-auth=ServiceAccountToken \
  --timeout=40m
```

**Node pool flag:**
```bash
gcloud container node-pools create gpu-pool \
  ...existing flags... \
  --enable-image-streaming \
  --secondary-boot-disk=disk-image=global/images/vllm-cache-v<VERSION>,mode=CONTAINER_IMAGE_CACHE
```

**Requirements:**
- GKE 1.30.1-gke.1329000+ (current GKE stable exceeds this)
- Node pool service account needs `roles/artifactregistry.reader`
- Disk size ≥ uncompressed image size: 8GB compressed → ~15-20GB uncompressed → use 20GB
- Builder timeout: use `--timeout=40m` (default 20m is insufficient for 8GB image)
- GCS bucket needed for build logs

**Caveat — operational overhead on vLLM version update:**
1. Build new disk image with new vLLM version
2. Create new node pool pointing to new disk image
3. Drain and delete old node pool

This is the main maintenance cost of the approach.

**Secondary boot disk cost:** ~20GB pd-standard per GPU node-hour = ~$0.002/hr when node
is running. Negligible (GPU node is usually off with scale-to-zero).

---

## Combined Result

```
Current:
  30s node + 6.5m pull (11GB) + 1.5m vLLM load = ~9 min

After PV only:
  30s node + 5m pull (8GB)  + 30s vLLM load   = ~6 min

After PV + Secondary Boot Disk:
  30s node + seconds (local disk) + 30s vLLM load = ~1-2 min
```

---

## Cold Start Benchmarks (Recorded from Phase 2 Runs)

All runs against GKE g2-standard-4 + NVIDIA L4, us-central1-a, Artifact Registry same region.

| Run | Config | Queue spike → first token | Bottleneck |
|---|---|---|---|
| Run 21:57 | vLLM baked image (11GB) | ~9 min | image pull |
| Run 23:50 | vLLM baked image (11GB) | ~9.5 min | image pull |
| Image Streaming run | 11GB + streaming | worse | lazy remote IO |

Prometheus breakdown (run 23:50, confirmed):
```
23:50:08 — queue spike
23:50:38 — GPU node online (30s provision)
23:58:58 — GPU power 17W → 33W (image pull complete, vLLM initializing)
23:59:28 — VRAM 3.7GB → 18.4GB (model loaded into GPU)
23:59:38 — first tokens at ~9 tok/s
```

**Note on GPU UTIL = 0:** Expected behavior. Prometheus scrapes every 15s; the ~1 min of
active inference with a 1.5B model is too bursty for 15s samples to capture. GPU was
active — confirmed by power draw (33W) and VRAM allocation (18.4GB).

---

## Implementation Status

- [ ] PV for model weights (remove vllm-custom/, add PVC + init Job)
- [ ] GKE Secondary Boot Disk (build disk image, update deploy-gcp.sh)
- [ ] Verify cold start ≤ 2 min end-to-end
