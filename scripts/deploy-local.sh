#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="llm-gateway"
NAMESPACE="llm-gateway"

echo "=== Phase 1: Local Deployment ==="

# 1. Create k3d cluster with port mapping
if k3d cluster list | grep -q "$CLUSTER_NAME"; then
  echo "Cluster '$CLUSTER_NAME' already exists, skipping creation."
else
  echo "Creating k3d cluster..."
  k3d cluster create "$CLUSTER_NAME" --port "8080:80@loadbalancer"
fi

# 2. Build Docker images
echo "Building gateway image..."
docker build -t gateway:local ./gateway

echo "Building worker image..."
docker build -t worker:local ./worker

# 3. Import images into k3d
echo "Importing images into k3d..."
k3d image import gateway:local worker:local -c "$CLUSTER_NAME"

# 4. Install KEDA (if not already installed)
if ! kubectl get namespace keda &>/dev/null; then
  echo "Installing KEDA..."
  helm repo add kedacore https://kedacore.github.io/charts 2>/dev/null || true
  helm repo update
  helm install keda kedacore/keda --namespace keda --create-namespace --wait
else
  echo "KEDA already installed, skipping."
fi

# 5. Create namespace and apply manifests
echo "Applying Kubernetes manifests..."
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/ -n "$NAMESPACE"

# 6. Patch worker for Phase 1: vLLM runs on host, not in cluster
echo "Patching worker VLLM_URL for local deployment..."
kubectl set env deployment/worker VLLM_URL=http://host.docker.internal:8000 -n "$NAMESPACE"

# 7. Apply monitoring stack
echo "Deploying monitoring stack..."
kubectl apply -f monitoring/prometheus.yaml -n "$NAMESPACE"

# 8. Wait for rollout
echo "Waiting for Redis..."
kubectl rollout status deployment/redis -n "$NAMESPACE" --timeout=60s

echo "Waiting for Gateway..."
kubectl rollout status deployment/gateway -n "$NAMESPACE" --timeout=60s

echo ""
echo "=== Deployment Complete ==="
kubectl get all -n "$NAMESPACE"
echo ""
echo "Gateway:    http://localhost:8080"
echo "Grafana:    kubectl port-forward svc/grafana 3000:3000 -n $NAMESPACE"
echo "Prometheus: kubectl port-forward svc/prometheus 9090:9090 -n $NAMESPACE"
echo ""
echo "NOTE: Start vLLM separately on the host:"
echo "  docker run --gpus all -p 8000:8000 --ipc=host \\"
echo "    vllm/vllm-openai --model Qwen/Qwen2.5-1.5B-Instruct \\"
echo "    --max-model-len 4096 --gpu-memory-utilization 0.8 --enforce-eager"
