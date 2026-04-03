#!/usr/bin/env bash
# deploy.sh — Deploy AxiomNode to a specific environment
# Usage: ./deploy.sh <dev|stg|prod>
set -euo pipefail

ENV="${1:?Usage: $0 <dev|stg|prod>}"
OVERLAY_DIR="kubernetes/overlays/${ENV}"
KUBECTL="kubectl"

if command -v k3s &>/dev/null; then
  KUBECTL="k3s kubectl"
fi

if [[ ! -d "$OVERLAY_DIR" ]]; then
  echo "Error: Overlay not found: $OVERLAY_DIR"
  exit 1
fi

echo "=== Deploying AxiomNode to ${ENV} ==="

# Validate manifests first
echo "[1/3] Validating manifests..."
$KUBECTL apply -k "$OVERLAY_DIR" --dry-run=server 2>&1 || {
  echo "Validation failed. Aborting deployment."
  exit 1
}

# Apply manifests
echo "[2/3] Applying manifests..."
$KUBECTL apply -k "$OVERLAY_DIR"

# Wait for rollout
echo "[3/3] Waiting for rollouts..."
NAMESPACE="axiomnode-${ENV}"
DEPLOYMENTS=$($KUBECTL get deployments -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}')

for deploy in $DEPLOYMENTS; do
  echo "  Waiting for ${deploy}..."
  $KUBECTL rollout status deployment/"$deploy" -n "$NAMESPACE" --timeout=300s || {
    echo "WARNING: ${deploy} rollout did not complete within timeout"
  }
done

echo ""
echo "=== Deployment to ${ENV} complete ==="
$KUBECTL get pods -n "$NAMESPACE"
