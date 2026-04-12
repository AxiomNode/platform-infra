#!/usr/bin/env bash
# migrate-db.sh — Synchronize Prisma schemas for all microservices
# Usage: ./migrate-db.sh <environment>
set -euo pipefail

ENV="${1:?Usage: $0 <stg|prod>}"

if [[ "$ENV" != "stg" && "$ENV" != "prod" ]]; then
  echo "Error: '$ENV' is not a valid Kubernetes target."
  echo "Use 'stg' or 'prod'."
  echo "For local development (dev), use local compose migrations per service."
  exit 1
fi

NAMESPACE="axiomnode-${ENV}"
KUBECTL="kubectl"

if command -v k3s &>/dev/null; then
  KUBECTL="k3s kubectl"
fi

SERVICES=("microservice-quizz-api" "microservice-wordpass-api" "microservice-users-api")

echo "=== Synchronizing Prisma schemas for ${ENV} ==="

for svc in "${SERVICES[@]}"; do
  echo ""
  echo "--- Syncing schema: ${svc} ---"
  POD=$($KUBECTL get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=${svc}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [[ -z "$POD" ]]; then
    echo "WARNING: No pod found for ${svc}, skipping."
    continue
  fi

  echo "Pod: ${POD}"
  $KUBECTL exec -n "$NAMESPACE" "$POD" -- npx prisma db push
  echo "${svc}: schema sync complete."
done

echo ""
echo "=== All schema sync operations complete ==="
