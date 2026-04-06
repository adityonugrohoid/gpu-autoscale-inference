# Cold Start Optimization — Research, Plan & Results

**Status:** Implemented and benchmarked on GCP GKE T4 Spot (us-east1-d), 2026-04-05.
**Result:** Cold start reduced from **659 s (11 min)** → **338 s (5.6 min)** — **48% improvement**.

## Problem

vLLM on GKE with scale-to-zero GPU nodes had an ~11 minute cold start:

```
2.5m — Cluster Autoscaler provisions GPU VM (n1-standard-4 + T4 Spot)
6.5m — GPU node pulls 11GB Docker image from Artifact Registry (~28MB/s)
2m   — vLLM starts Python/CUDA and loads model weights into VRAM
────
~11m total from queue spike to first token
```

The 28MB/s pull speed is not network-bandwidth-limited (n1-standard-4 has 10Gbps). It is
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
  --project-name=project-15693e31-5f7e-4fce-b55 \
  --image-name=vllm-cache-v<VERSION> \
  --zone=us-central1-a \
  --gcs-path=gs://<LOG_BUCKET> \
  --disk-size-gb=20 \
  --container-image=us-docker.pkg.dev/project-15693e31-5f7e-4fce-b55/llm-gateway/vllm-openai:latest \
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

## Combined Result — Improvement from each optimization

Hardware: GCP GKE, NVIDIA T4 Spot, n1-standard-4, us-east1-d. Measured 2026-04-05.

| Phase | Baseline (11 GB baked) | After Opt 1 (PV only) | After Opt 1 + Opt 2 (PV + SBD) |
|---|---|---|---|
| GPU node provision | ~2.5 min | ~2.5 min | ~2.5 min |
| Container image pull | **~6.5 min** (11 GB) | **~5 min** (8 GB) | **~30 s** (local disk) |
| vLLM boot + model load to VRAM | ~2 min (baked) | ~2.5 min (PVC → VRAM) | ~2.5 min (PVC → VRAM) |
| **Total** | **~11 min (659s)** ✅ measured | **~10 min** ⚠ estimated | **~5.6 min (338s)** ✅ measured |
| **Savings vs baseline** | — | **~1.5 min (~14%)** | **~5.4 min (~48%)** |

> ⚠ The "PV only" column is computed from the 8 GB image-pull math + observed PVC load
> time. It was never run in isolation as a separate benchmark — the two optimizations
> were measured together. PV's main contribution is structural: it makes a stock 8 GB
> image cacheable on the secondary boot disk in the first place.

**Why the remaining 5.6 min cannot easily go lower:**

| Phase | Duration | Why it stays |
|---|---|---|
| GCE boot + NVIDIA driver init | ~2.5 min | Outside GKE's control — hardware bring-up |
| Container start (image already local) | ~30 s | Pod scheduler + containerd unpack |
| 3.5 GB model from PVC → VRAM | ~2.5 min | Network-attached PD bandwidth, not GPU-bound |

Further reduction requires either GPU-aware node warming (a min-1 idle GPU node — defeats
scale-to-zero) or moving the model into a tmpfs / Local SSD on the secondary boot disk
itself (adds complexity, rebuild burden). Out of scope for v0.1.

---

## Earlier Exploration on L4 (us-central1-a)

Before the project moved hardware to T4 Spot in us-east1-d, two baseline runs were
measured on `g2-standard-4 + NVIDIA L4` in `us-central1-a`. These are kept for historical
context — no L4 run was ever measured with the optimizations applied.

| Run | Config | Queue spike → first token | Bottleneck |
|---|---|---|---|
| Run 21:57 | vLLM baked image (11GB) | ~9 min | image pull |
| Run 23:50 | vLLM baked image (11GB) | ~9.5 min | image pull |
| Image Streaming run | 11GB + streaming | worse | lazy remote IO |

Prometheus breakdown (run 23:50, confirmed) — the only fully traced cold-start in the
project history:
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

The L4 baseline (~9-9.5 min) and T4 baseline (~11 min) differ by ~2 min — different
region, different network path, different runs at different times. The image-pull
bottleneck is similar in both cases because it is gated by 4-vCPU containerd
decompression, not GPU class.

---

## Implementation Status

- [x] PV for model weights — `k8s/vllm-pvc.yaml`, `k8s/vllm-model-init-job.yaml`, vLLM deployment mounts PVC
- [x] GKE Secondary Boot Disk — `vllm-node-cache-20260405` (50 GB, us-east1-d), built via `scripts/build-node-cache.sh`
- [x] Cold start verified at 5.6 min end-to-end (run-20260405-015400, run-20260406-190041)
