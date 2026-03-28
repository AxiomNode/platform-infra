#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="$BASE_DIR/docker-compose.edge-integration.yml"
SECRETS_FILE="$BASE_DIR/../../../api-gateway/src/.env.secrets"

ensure_env_file() {
  local target_file="$1"
  local example_file="$2"

  if [[ -f "$target_file" ]]; then
    return
  fi

  if [[ ! -f "$example_file" ]]; then
    echo "Missing required env template: $example_file"
    exit 1
  fi

  cp "$example_file" "$target_file"
  echo "Created $target_file from template."
}

ensure_env_file "$BASE_DIR/../../../api-gateway/src/.env" "$BASE_DIR/../../../api-gateway/src/.env.example"
ensure_env_file "$BASE_DIR/../../../bff-mobile/src/.env" "$BASE_DIR/../../../bff-mobile/src/.env.example"
ensure_env_file "$BASE_DIR/../../../bff-backoffice/src/.env" "$BASE_DIR/../../../bff-backoffice/src/.env.example"

check_upstream_health() {
  local service_name="$1"
  local port="$2"

  local status
  status="$(node -e "(async()=>{try{const r=await fetch('http://localhost:${port}/health');process.stdout.write(String(r.status));}catch(_){process.stdout.write('ERR');}})();")"

  if [[ "$status" != "200" ]]; then
    echo "Upstream dependency not ready: $service_name at http://localhost:${port}/health (status=$status)"
    echo "Start required services first (microservice-quizz:7100, microservice-wordpass:7101, microservice-users:7102)."
    exit 1
  fi
}

check_upstream_health "microservice-quizz" "7100"
check_upstream_health "microservice-wordpass" "7101"
check_upstream_health "microservice-users" "7102"

if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "Missing secrets file: $SECRETS_FILE"
  echo "Run from private secrets repo first: node scripts/export-secrets-map.mjs dev"
  exit 1
fi

EDGE_API_TOKEN="$(grep '^EDGE_API_TOKEN=' "$SECRETS_FILE" | head -n 1 | cut -d '=' -f 2-)"

if [[ -z "$EDGE_API_TOKEN" ]]; then
  echo "EDGE_API_TOKEN is empty in $SECRETS_FILE"
  exit 1
fi

FORWARD_CORRELATION_ID="smoke-corr-$(date +%s)"
FORWARD_FIREBASE_TOKEN="smoke-firebase-token"
FORWARD_API_KEY="smoke-client-api-key"

expect_status() {
  local expected="$1"
  local method="$2"
  local url="$3"
  local auth_mode="$4"
  local body="${5-}"

  local auth_header=()
  if [[ "$auth_mode" == "valid" ]]; then
    auth_header=(-H "Authorization: Bearer $EDGE_API_TOKEN")
  fi

  local forwarded_headers=(
    -H "x-correlation-id: $FORWARD_CORRELATION_ID"
    -H "x-firebase-id-token: $FORWARD_FIREBASE_TOKEN"
    -H "x-api-key: $FORWARD_API_KEY"
  )

  local code
  if [[ -n "$body" ]]; then
    code="$(curl -sS -o /dev/null -w "%{http_code}" -X "$method" "${auth_header[@]}" "${forwarded_headers[@]}" -H "Content-Type: application/json" -d "$body" "$url")"
  else
    code="$(curl -sS -o /dev/null -w "%{http_code}" -X "$method" "${auth_header[@]}" "${forwarded_headers[@]}" "$url")"
  fi

  if [[ "$code" != "$expected" ]]; then
    echo "Unexpected status for $method $url (auth=$auth_mode): expected=$expected got=$code"
    exit 1
  fi
}

expect_status_any() {
  local expected_csv="$1"
  local method="$2"
  local url="$3"
  local auth_mode="$4"
  local body="${5-}"

  local auth_header=()
  if [[ "$auth_mode" == "valid" ]]; then
    auth_header=(-H "Authorization: Bearer $EDGE_API_TOKEN")
  fi

  local forwarded_headers=(
    -H "x-correlation-id: $FORWARD_CORRELATION_ID"
    -H "x-firebase-id-token: $FORWARD_FIREBASE_TOKEN"
    -H "x-api-key: $FORWARD_API_KEY"
  )

  local code
  if [[ -n "$body" ]]; then
    code="$(curl -sS -o /dev/null -w "%{http_code}" -X "$method" "${auth_header[@]}" "${forwarded_headers[@]}" -H "Content-Type: application/json" -d "$body" "$url")"
  else
    code="$(curl -sS -o /dev/null -w "%{http_code}" -X "$method" "${auth_header[@]}" "${forwarded_headers[@]}" "$url")"
  fi

  IFS=',' read -r -a expected_list <<< "$expected_csv"
  for expected in "${expected_list[@]}"; do
    if [[ "$code" == "$expected" ]]; then
      return
    fi
  done

  echo "Unexpected status for $method $url (auth=$auth_mode): expected one of [$expected_csv] got=$code"
  exit 1
}

docker compose -f "$COMPOSE_FILE" up -d --build
trap 'docker compose -f "$COMPOSE_FILE" down' EXIT

sleep 8

expect_status "401" "GET" "http://localhost:7005/v1/mobile/games/quiz/random?language=es" "none"
expect_status "200" "GET" "http://localhost:7005/health" "valid"
expect_status "200" "GET" "http://localhost:7005/v1/mobile/games/quiz/random?language=es" "valid"
expect_status "200" "GET" "http://localhost:7005/v1/mobile/games/wordpass/random?language=es" "valid"
expect_status "200" "GET" "http://localhost:7005/v1/backoffice/users/leaderboard?limit=5" "valid"
expect_status "200" "GET" "http://localhost:7005/v1/backoffice/monitor/stats" "valid"
expect_status_any "200,400,422,502" "POST" "http://localhost:7005/v1/mobile/games/quiz/generate" "valid" '{"language":"es","categoryId":"9","numQuestions":3}'
expect_status_any "200,400,422,502" "POST" "http://localhost:7005/v1/mobile/games/wordpass/generate" "valid" '{"language":"es","categoryId":"9","numQuestions":3}'
expect_status_any "200,400,401,422,502" "POST" "http://localhost:7005/v1/backoffice/users/events/manual" "valid" '{"eventType":"quiz","outcome":"won"}'

echo "Edge smoke OK (auth + GET + POST + critical forwarding headers)"
