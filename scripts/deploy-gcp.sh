#!/usr/bin/env bash
set -euo pipefail

PROJECT="sonorous-reach-438808-c6"
REGION="us-central1"
CLUSTER="llm-gateway"
NAMESPACE="llm-gateway"
REGISTRY="us-docker.pkg.dev/${PROJECT}/llm-gateway"

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

# 3. Configure Docker auth for Artifact Registry
echo "Configuring Docker auth..."
gcloud auth configure-docker us-docker.pkg.dev --quiet

# 4. Build and push images
echo "Building and pushing gateway image..."
docker build -t "${REGISTRY}/gateway:latest" ./gateway
docker push "${REGISTRY}/gateway:latest"

echo "Building and pushing worker image..."
docker build -t "${REGISTRY}/worker:latest" ./worker
docker push "${REGISTRY}/worker:latest"

# 5. Create GKE cluster (if not exists)
if gcloud container clusters describe "$CLUSTER" --region "$REGION" --project "$PROJECT" &>/dev/null; then
  echo "Cluster '$CLUSTER' already exists, skipping creation."
else
  echo "Creating GKE cluster (1x e2-standard-2 CPU node)..."
  gcloud container clusters create "$CLUSTER" \
    --project "$PROJECT" \
    --region "$REGION" \
    --num-nodes 1 \
    --machine-type e2-standard-2 \
    --release-channel regular \
    --enable-autoscaling --min-nodes 1 --max-nodes 2
fi

# 6. Create GPU node pool (if not exists)
if gcloud container node-pools describe gpu-pool --cluster "$CLUSTER" --region "$REGION" --project "$PROJECT" &>/dev/null; then
  echo "GPU node pool already exists, skipping creation."
else
  echo "Creating GPU node pool (n1-standard-4 + T4, spot, 0-1 nodes)..."
  gcloud container node-pools create gpu-pool \
    --cluster "$CLUSTER" \
    --project "$PROJECT" \
    --region "$REGION" \
    --machine-type n1-standard-4 \
    --accelerator type=nvidia-tesla-t4,count=1 \
    --spot \
    --num-nodes 0 \
    --min-nodes 0 \
    --max-nodes 1 \
    --enable-autoscaling \
    --node-taints="nvidia.com/gpu=present:NoSchedule"
fi

# 7. Get cluster credentials
echo "Fetching cluster credentials..."
gcloud container clusters get-credentials "$CLUSTER" --region "$REGION" --project "$PROJECT"

# 8. Install KEDA (if not already installed)
if ! kubectl get namespace keda &>/dev/null; then
  echo "Installing KEDA..."
  helm repo add kedacore https://kedacore.github.io/charts 2>/dev/null || true
  helm repo update
  helm install keda kedacore/keda --namespace keda --create-namespace --wait
else
  echo "KEDA already installed, skipping."
fi

# 9. Apply base manifests
echo "Applying Kubernetes manifests..."
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/ -n "$NAMESPACE"

# 10. Set container images to Artifact Registry
echo "Setting container images to Artifact Registry..."
kubectl set image deployment/gateway gateway="${REGISTRY}/gateway:latest" -n "$NAMESPACE"
kubectl set image deployment/worker worker="${REGISTRY}/worker:latest" -n "$NAMESPACE"

# 11. Apply GCP GPU patch for vLLM
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
echo "WARNING: GKE control plane costs ~\$0.10/hr + GPU node ~\$0.15/hr (spot)."
echo "ALWAYS tear down after session: ./scripts/destroy-gcp.sh"
