#!/usr/bin/env bash
set -euo pipefail

echo "Deleting k3d cluster 'llm-gateway'..."
k3d cluster delete llm-gateway
echo "Done."
