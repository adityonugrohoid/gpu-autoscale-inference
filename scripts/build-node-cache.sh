#!/usr/bin/env bash
# build-node-cache.sh — Build GKE Secondary Boot Disk image for vLLM
# Run once per vLLM version change. Takes ~40 min.
# After completion, set VLLM_DISK_IMAGE in scripts/deploy-gcp.sh and recreate the GPU node pool.
set -euo pipefail

PROJECT="project-15693e31-5f7e-4fce-b55"
REGION="us-east1"
REGISTRY="us-docker.pkg.dev/${PROJECT}/llm-gateway"
DISK_NAME="vllm-node-cache-$(date +%Y%m%d)"
DISK_SIZE_GB=50
LOG_BUCKET="gs://${PROJECT}-node-cache-logs"

# 1. Check Go >= 1.21 (required by gke-disk-image-builder)
echo "Checking Go version..."
# Add common non-standard Go install locations to PATH
export PATH="$HOME/go-install/go/bin:/usr/local/go/bin:$PATH"
if ! command -v go &>/dev/null; then
  echo "ERROR: Go not found. Install Go >= 1.21: https://go.dev/dl/"
  exit 1
fi
GO_VERSION=$(go version | awk '{print $3}' | sed 's/go//')
GO_MAJOR=$(echo "$GO_VERSION" | cut -d. -f1)
GO_MINOR=$(echo "$GO_VERSION" | cut -d. -f2)
if [ "$GO_MAJOR" -lt 1 ] || { [ "$GO_MAJOR" -eq 1 ] && [ "$GO_MINOR" -lt 21 ]; }; then
  echo "ERROR: Go >= 1.21 required, found ${GO_VERSION}. Install: https://go.dev/dl/"
  exit 1
fi
echo "Go ${GO_VERSION} OK"

# 2. Create GCS log bucket (idempotent)
echo "Creating GCS log bucket ${LOG_BUCKET}..."
gcloud storage buckets create "$LOG_BUCKET" \
  --project="$PROJECT" \
  --location="$REGION" 2>/dev/null || echo "  Bucket already exists, skipping."

# 3. Pull, retag, push vLLM base image to Artifact Registry
# Builder VM uses ServiceAccountToken auth — needs image in AR, not Docker Hub
echo "Pushing vLLM base image to Artifact Registry..."
gcloud auth print-access-token | docker login -u oauth2accesstoken --password-stdin us-docker.pkg.dev
docker pull vllm/vllm-openai:latest
docker tag vllm/vllm-openai:latest "${REGISTRY}/vllm-openai:latest"
docker push "${REGISTRY}/vllm-openai:latest"

# 4. Clone ai-on-gke tools (sparse checkout — builder only)
TOOLS_DIR=$(mktemp -d)
echo "Cloning gke-disk-image-builder into ${TOOLS_DIR}..."
git clone --filter=blob:none --sparse https://github.com/ai-on-gke/tools.git "$TOOLS_DIR"
cd "$TOOLS_DIR"
git sparse-checkout set gke-disk-image-builder
cd gke-disk-image-builder

# 5. Build the disk image
echo "Building GCE disk image ${DISK_NAME} (~40 min)..."
go mod tidy
go run ./cli \
  --project-name="$PROJECT" \
  --image-name="$DISK_NAME" \
  --zone="${REGION}-a" \
  --gcs-path="$LOG_BUCKET" \
  --disk-size-gb="$DISK_SIZE_GB" \
  --container-image="${REGISTRY}/vllm-openai:latest" \
  --timeout=40m \
  --image-pull-auth=ServiceAccountToken

cd -

echo ""
echo "=== Secondary Boot Disk Image Built ==="
echo "Image name: ${DISK_NAME}"
echo ""
echo "Next steps:"
echo "  1. Open scripts/deploy-gcp.sh"
echo "  2. Set: VLLM_DISK_IMAGE=\"${DISK_NAME}\""
echo "  3. Delete the existing GPU node pool (if any):"
echo "       gcloud container node-pools delete gpu-pool --cluster llm-gateway --zone ${REGION}-a --project $PROJECT"
echo "  4. Re-run ./scripts/deploy-gcp.sh — new node pool will boot with disk cache"
echo "  5. Expected cold start: ≤ 2 min (vs ~6 min with PV only)"
echo ""
echo "NOTE: vLLM version change requires rebuilding the disk image and recreating the node pool."
