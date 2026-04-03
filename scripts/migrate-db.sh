#!/usr/bin/env bash
# migrate-db.sh — Run Prisma migrations for all microservices
# Usage: ./migrate-db.sh <environment>
set -euo pipefail

ENV="${1:?Usage: $0 <dev|stg|prod>}"
NAMESPACE="axiomnode-${ENV}"
KUBECTL="kubectl"

if command -v k3s &>/dev/null; then
  KUBECTL="k3s kubectl"
fi

SERVICES=("microservice-quizz-api" "microservice-wordpass-api" "microservice-users-api")

echo "=== Running Prisma migrations for ${ENV} ==="

for svc in "${SERVICES[@]}"; do
  echo ""
  echo "--- Migrating: ${svc} ---"
  POD=$($KUBECTL get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=${svc}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [[ -z "$POD" ]]; then
    echo "WARNING: No pod found for ${svc}, skipping."
    continue
  fi

  echo "Pod: ${POD}"
  $KUBECTL exec -n "$NAMESPACE" "$POD" -- npx prisma migrate deploy
  echo "${svc}: migration complete."
done

echo ""
echo "=== All migrations complete ==="
