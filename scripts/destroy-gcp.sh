#!/usr/bin/env bash
set -euo pipefail

PROJECT="project-15693e31-5f7e-4fce-b55"
REGION="us-east1"
CLUSTER="llm-gateway"

echo "=== Destroying GCP GKE Resources ==="

# 1. Delete GKE cluster
echo "Deleting GKE cluster '$CLUSTER'..."
gcloud container clusters delete "$CLUSTER" \
  --zone "${REGION}-d" \
  --project "$PROJECT" \
  --quiet

# 2. Optionally clean Artifact Registry images
echo ""
read -rp "Delete Artifact Registry images? (y/N): " CLEAN_REGISTRY
if [[ "$CLEAN_REGISTRY" =~ ^[Yy]$ ]]; then
  echo "Cleaning Artifact Registry..."
  gcloud artifacts docker images delete "us-docker.pkg.dev/${PROJECT}/llm-gateway/gateway" --quiet 2>/dev/null || true
  gcloud artifacts docker images delete "us-docker.pkg.dev/${PROJECT}/llm-gateway/worker" --quiet 2>/dev/null || true
  echo "Registry images deleted."
else
  echo "Skipping registry cleanup."
fi

echo ""
echo "=== Teardown Complete ==="
echo "Verify no resources remain: https://console.cloud.google.com/kubernetes/list?project=$PROJECT"
