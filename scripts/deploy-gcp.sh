#!/usr/bin/env bash
set -euo pipefail

PROJECT="project-15693e31-5f7e-4fce-b55"
REGION="us-east1"
CLUSTER="llm-gateway"
NAMESPACE="llm-gateway"
REGISTRY="us-docker.pkg.dev/${PROJECT}/llm-gateway"
VLLM_DISK_IMAGE="vllm-node-cache-20260405"

# Auto-detect kubectl (prefer gcloud SDK to avoid broken Docker Desktop symlinks)
SDK_ROOT=$(gcloud info --format="value(installation.sdk_root)" 2>/dev/null || true)
if [ -n "$SDK_ROOT" ] && [ -f "$SDK_ROOT/bin/kubectl" ]; then
  kubectl() { "$SDK_ROOT/bin/kubectl" "$@"; }
elif ! kubectl version --client &>/dev/null 2>&1; then
  echo "ERROR: kubectl not found. Install via: gcloud components install kubectl"
  exit 1
fi

echo "=== Phase 2: GCP GKE Deployment ==="

# 1. Enable required APIs
echo "Enabling GCP APIs..."
gcloud services enable container.googleapis.com artifactregistry.googleapis.com --project "$PROJECT"

# 2. Create Artifact Registry repo (if not exists)
echo "Creating Artifact Registry repo..."
gcloud artifacts repositories describe llm-gateway \
  --location us --project "$PROJECT" &>/dev/null || \
gcloud artifacts repositories create llm-gateway \
  --repository-format=docker \
  --location=us \
  --project="$PROJECT"

# 3. Build and push images (Docker if available, Cloud Build otherwise)
if docker info &>/dev/null; then
  echo "Using Docker for image builds..."
  gcloud auth print-access-token | docker login -u oauth2accesstoken --password-stdin us-docker.pkg.dev

  echo "Building and pushing gateway image..."
  docker build -t "${REGISTRY}/gateway:latest" ./gateway
  docker push "${REGISTRY}/gateway:latest"

  echo "Building and pushing worker image..."
  docker build -t "${REGISTRY}/worker:latest" ./worker
  docker push "${REGISTRY}/worker:latest"

  echo "Pushing vLLM base image to Artifact Registry..."
  docker pull vllm/vllm-openai:latest
  docker tag vllm/vllm-openai:latest "${REGISTRY}/vllm-openai:latest"
  docker push "${REGISTRY}/vllm-openai:latest"
else
  echo "Docker not available, using Cloud Build..."
  gcloud services enable cloudbuild.googleapis.com --project "$PROJECT"

  echo "Building gateway image via Cloud Build..."
  gcloud builds submit ./gateway \
    --tag "${REGISTRY}/gateway:latest" \
    --project "$PROJECT" --quiet

  echo "Building worker image via Cloud Build..."
  gcloud builds submit ./worker \
    --tag "${REGISTRY}/worker:latest" \
    --project "$PROJECT" --quiet

  echo "Pushing vLLM base image via Cloud Build..."
  cat > /tmp/vllm-cloudbuild.yaml << 'CBEOF'
steps:
  - name: 'gcr.io/cloud-builders/docker'
    args: ['pull', 'vllm/vllm-openai:latest']
  - name: 'gcr.io/cloud-builders/docker'
    args: ['tag', 'vllm/vllm-openai:latest', '${_REGISTRY}/vllm-openai:latest']
  - name: 'gcr.io/cloud-builders/docker'
    args: ['push', '${_REGISTRY}/vllm-openai:latest']
timeout: '1800s'
substitutions:
  _REGISTRY: ''
CBEOF
  gcloud builds submit --no-source \
    --config=/tmp/vllm-cloudbuild.yaml \
    --substitutions="_REGISTRY=${REGISTRY}" \
    --project "$PROJECT" --quiet
fi

# 5. Create GKE cluster (if not exists)
if gcloud container clusters describe "$CLUSTER" --zone "${REGION}-d" --project "$PROJECT" &>/dev/null; then
  echo "Cluster '$CLUSTER' already exists, skipping creation."
else
  echo "Creating GKE cluster (1x e2-standard-2 CPU node, single-zone)..."
  gcloud container clusters create "$CLUSTER" \
    --project "$PROJECT" \
    --zone "${REGION}-d" \
    --num-nodes 1 \
    --machine-type e2-standard-2 \
    --release-channel None \
    --no-enable-autoupgrade \
    --enable-autoscaling --min-nodes 1 --max-nodes 2
fi

# 6. Create GPU node pool (if not exists)
if gcloud container node-pools describe gpu-pool --cluster "$CLUSTER" --zone "${REGION}-d" --project "$PROJECT" &>/dev/null; then
  echo "GPU node pool already exists, skipping creation."
else
  echo "Creating GPU node pool (n1-standard-4 + T4 SPOT, 0-1 nodes)..."
  SECONDARY_BOOT_DISK_FLAG=""
  if [ -n "${VLLM_DISK_IMAGE:-}" ]; then
    SECONDARY_BOOT_DISK_FLAG="--enable-image-streaming --secondary-boot-disk=disk-image=global/images/${VLLM_DISK_IMAGE},mode=CONTAINER_IMAGE_CACHE"
  fi
  gcloud container node-pools create gpu-pool \
    --cluster "$CLUSTER" \
    --project "$PROJECT" \
    --zone "${REGION}-d" \
    --machine-type n1-standard-4 \
    --accelerator type=nvidia-tesla-t4,count=1 \
    --spot \
    --num-nodes 0 \
    --min-nodes 0 \
    --max-nodes 1 \
    --enable-autoscaling \
    --node-taints="nvidia.com/gpu=present:NoSchedule" \
    ${SECONDARY_BOOT_DISK_FLAG}
fi

# 7. Get cluster credentials
echo "Fetching cluster credentials..."
gcloud container clusters get-credentials "$CLUSTER" --zone "${REGION}-d" --project "$PROJECT"

# 8. Install KEDA (if not already installed)
if ! kubectl get namespace keda &>/dev/null; then
  echo "Installing KEDA..."
  helm repo add kedacore https://kedacore.github.io/charts 2>/dev/null || true
  helm repo update
  helm install keda kedacore/keda --namespace keda --create-namespace --wait
else
  echo "KEDA already installed, skipping."
fi

# 9. Install kube-state-metrics (for pod/node count Grafana panels)
if ! kubectl get deployment kube-state-metrics -n kube-system &>/dev/null; then
  echo "Installing kube-state-metrics..."
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
  helm install kube-state-metrics prometheus-community/kube-state-metrics --namespace kube-system --wait
else
  echo "kube-state-metrics already installed, skipping."
fi

# 10. Apply base manifests
echo "Applying Kubernetes manifests..."
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/ -n "$NAMESPACE"

# 10. Apply PVC and model init job, wait for model download
echo "Applying PVC and model init job..."
kubectl apply -f k8s/vllm-pvc.yaml -n "$NAMESPACE"
kubectl apply -f k8s/vllm-model-init-job.yaml -n "$NAMESPACE"
echo "Waiting for model init job (downloads Qwen2.5-1.5B to PVC, ~5-7 min)..."
kubectl wait --for=condition=complete job/vllm-model-init \
  -n "$NAMESPACE" --timeout=600s

# 11. Set container images to Artifact Registry
echo "Setting container images to Artifact Registry..."
kubectl set image deployment/gateway gateway="${REGISTRY}/gateway:latest" -n "$NAMESPACE"
kubectl set image deployment/worker worker="${REGISTRY}/worker:latest" -n "$NAMESPACE"
kubectl set image deployment/vllm vllm="${REGISTRY}/vllm-openai:latest" -n "$NAMESPACE"

# 12. Apply GCP GPU patch for vLLM
echo "Applying GPU tolerations and nodeSelector to vLLM..."
kubectl patch deployment vllm -n "$NAMESPACE" --type=strategic --patch-file=k8s-cloud/gcp/vllm-gpu-patch.yaml

# 12. Apply monitoring stack
echo "Deploying monitoring stack..."
kubectl apply -f monitoring/prometheus.yaml -n "$NAMESPACE"
kubectl apply -f monitoring/dcgm-exporter.yaml -n "$NAMESPACE"

# 13. Wait for core services
echo "Waiting for Redis..."
kubectl rollout status deployment/redis -n "$NAMESPACE" --timeout=120s

echo "Waiting for Gateway..."
kubectl rollout status deployment/gateway -n "$NAMESPACE" --timeout=120s

# 14. Wait for LoadBalancer IP
echo "Waiting for LoadBalancer IP..."
for i in $(seq 1 30); do
  GATEWAY_IP=$(kubectl get svc gateway -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [ -n "$GATEWAY_IP" ]; then
    break
  fi
  echo "  Waiting for external IP... (${i}/30)"
  sleep 10
done

echo ""
echo "=== Deployment Complete ==="
kubectl get all -n "$NAMESPACE"
echo ""
if [ -n "${GATEWAY_IP:-}" ]; then
  echo "Gateway:    http://${GATEWAY_IP}"
else
  echo "Gateway:    (LoadBalancer IP not yet assigned — check: kubectl get svc gateway -n $NAMESPACE)"
fi
echo "Grafana:    kubectl port-forward svc/grafana 3000:3000 -n $NAMESPACE"
echo "Prometheus: kubectl port-forward svc/prometheus 9090:9090 -n $NAMESPACE"
echo ""
echo "Test health:"
echo "  curl http://${GATEWAY_IP:-<GATEWAY_IP>}/health"
echo ""
echo "Trigger scaling (6+ requests):"
echo "  for i in \$(seq 1 6); do"
echo "    curl -s -X POST http://${GATEWAY_IP:-<GATEWAY_IP>}/generate \\"
echo "      -H 'Content-Type: application/json' \\"
echo "      -d '{\"prompt\":\"Explain autoscaling\"}' &"
echo "  done"
echo ""
echo "WARNING: GKE control plane costs ~\$0.10/hr + GPU Spot node (T4) ~\$0.11/hr."
echo "ALWAYS tear down after session: ./scripts/destroy-gcp.sh"
