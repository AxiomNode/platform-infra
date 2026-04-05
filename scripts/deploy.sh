#!/usr/bin/env bash
# deploy.sh — Deploy AxiomNode to a specific environment
# Usage: ./deploy.sh <stg|prod>
set -euo pipefail

ENV="${1:?Usage: $0 <stg|prod>}"

if [[ "$ENV" != "stg" && "$ENV" != "prod" ]]; then
  echo "Error: '$ENV' is not a valid Kubernetes target."
  echo "Use 'stg' or 'prod'."
  echo "For local development (dev), use: ./scripts/dev-local-stack.sh up"
  exit 1
fi

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

NAMESPACE="axiomnode-${ENV}"

echo "[0/4] Ensuring GHCR pull secret..."
if [[ -z "${GHCR_PULL_USERNAME:-}" || -z "${GHCR_PULL_TOKEN:-}" ]]; then
  echo "Error: GHCR_PULL_USERNAME and GHCR_PULL_TOKEN are required for private GHCR images."
  echo "Export them before deploy, e.g.:"
  echo "  export GHCR_PULL_USERNAME=<github-username>"
  echo "  export GHCR_PULL_TOKEN=<token-with-read-packages>"
  exit 1
fi

$KUBECTL create namespace "$NAMESPACE" --dry-run=client -o yaml | $KUBECTL apply -f -
$KUBECTL -n "$NAMESPACE" create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io \
  --docker-username="$GHCR_PULL_USERNAME" \
  --docker-password="$GHCR_PULL_TOKEN" \
  --dry-run=client -o yaml | $KUBECTL apply -f -
$KUBECTL patch serviceaccount default -n "$NAMESPACE" --type=merge -p '{"imagePullSecrets":[{"name":"ghcr-pull"}]}' >/dev/null

# Validate manifests first
echo "[1/4] Validating manifests..."
$KUBECTL apply -k "$OVERLAY_DIR" --dry-run=server 2>&1 || {
  echo "Validation failed. Aborting deployment."
  exit 1
}

# Apply manifests
echo "[2/4] Applying manifests..."
$KUBECTL apply -k "$OVERLAY_DIR"

# Wait for rollout
echo "[3/4] Waiting for rollouts..."
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
