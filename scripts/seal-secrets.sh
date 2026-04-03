#!/usr/bin/env bash
# seal-secrets.sh — Create and seal Kubernetes secrets for AxiomNode
# Usage: ./seal-secrets.sh <environment> [secrets-file]
# Example: ./seal-secrets.sh dev secrets/dev.env
set -euo pipefail

ENV="${1:?Usage: $0 <dev|stg|prod> [secrets-file]}"
SECRETS_FILE="${2:-secrets/${ENV}.env}"
NAMESPACE="axiomnode-${ENV}"
KUBECTL="kubectl"
OUTPUT_DIR="kubernetes/overlays/${ENV}/sealed-secrets"

# Use k3s kubectl if on VPS
if command -v k3s &>/dev/null; then
  KUBECTL="k3s kubectl"
fi

if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "Error: Secrets file not found: $SECRETS_FILE"
  echo "Expected format (key=value pairs):"
  echo "  QUIZZ_DB_USER=quiz"
  echo "  QUIZZ_DB_PASSWORD=secret"
  echo "  WORDPASS_DB_USER=wordpass"
  echo "  WORDPASS_DB_PASSWORD=secret"
  echo "  USERS_DB_USER=users"
  echo "  USERS_DB_PASSWORD=secret"
  echo "  FIREBASE_CREDENTIALS=<base64-json>"
  exit 1
fi

echo "=== Sealing secrets for ${ENV} (namespace: ${NAMESPACE}) ==="

mkdir -p "$OUTPUT_DIR"
generated_files=()

# Source the secrets file
set -a
source "$SECRETS_FILE"
set +a

# --- Database secrets ---
for svc in quizz wordpass users; do
  SVC_UPPER=$(echo "$svc" | tr '[:lower:]' '[:upper:]')
  USER_VAR="${SVC_UPPER}_DB_USER"
  PASS_VAR="${SVC_UPPER}_DB_PASSWORD"
  DB_VAR="${SVC_UPPER}_DB_NAME"

  DB_USER="${!USER_VAR:-$svc}"
  DB_PASS="${!PASS_VAR:?Missing $PASS_VAR}"
  DB_NAME="${!DB_VAR:-${svc}db}"
  DB_HOST="${svc}-db"
  DB_PORT="5432"

  if [[ "$ENV" == "prod" ]]; then
    HOST_VAR="${SVC_UPPER}_DB_HOST"
    PORT_VAR="${SVC_UPPER}_DB_PORT"
    DB_HOST="${!HOST_VAR:?Missing $HOST_VAR for prod}"
    DB_PORT="${!PORT_VAR:-5432}"
  fi

  DATABASE_URL="postgresql://${DB_USER}:${DB_PASS}@${DB_HOST}:${DB_PORT}/${DB_NAME}?schema=public"

  echo "Creating sealed secret: ${svc}-db-secret"
  $KUBECTL create secret generic "${svc}-db-secret" \
    --namespace="$NAMESPACE" \
    --from-literal="username=${DB_USER}" \
    --from-literal="password=${DB_PASS}" \
    --from-literal="database-url=${DATABASE_URL}" \
    --dry-run=client -o yaml | \
    kubeseal --format yaml --cert sealed-secrets-cert.pem \
    > "${OUTPUT_DIR}/${svc}-db-secret.yaml"
  generated_files+=("${svc}-db-secret.yaml")
done

# --- Firebase credentials (users service) ---
if [[ -n "${FIREBASE_CREDENTIALS_FILE:-}" ]] && [[ -f "$FIREBASE_CREDENTIALS_FILE" ]]; then
  echo "Creating sealed secret: firebase-credentials"
  $KUBECTL create secret generic firebase-credentials \
    --namespace="$NAMESPACE" \
    --from-file="firebase-credentials.json=${FIREBASE_CREDENTIALS_FILE}" \
    --dry-run=client -o yaml | \
    kubeseal --format yaml --cert sealed-secrets-cert.pem \
    > "${OUTPUT_DIR}/firebase-credentials.yaml"
  generated_files+=("firebase-credentials.yaml")
fi

{
  echo "apiVersion: kustomize.config.k8s.io/v1beta1"
  echo "kind: Kustomization"
  echo ""
  echo "resources:"
  for file in "${generated_files[@]}"; do
    echo "  - ${file}"
  done
} > "${OUTPUT_DIR}/kustomization.yaml"

echo ""
echo "Sealed secrets written to ${OUTPUT_DIR}/"
echo "Kustomization generated: ${OUTPUT_DIR}/kustomization.yaml"
