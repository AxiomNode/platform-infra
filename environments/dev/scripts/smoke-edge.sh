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
    echo "Start required services first (microservice-quizz:7100, microservice-wordpass:7101, microservice-users:7102, ai-engine-api:7001)."
    exit 1
  fi
}

check_upstream_health "microservice-quizz" "7100"
check_upstream_health "microservice-wordpass" "7101"
check_upstream_health "microservice-users" "7102"
check_upstream_health "ai-engine-api" "7001"

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
FORWARD_DEV_FIREBASE_UID="smoke-dev-firebase-uid"
FORWARD_API_KEY="smoke-client-api-key"
SMOKE_PROFILE_DISPLAY_NAME="Edge Smoke User ${FORWARD_CORRELATION_ID}"
SMOKE_PROFILE_PREFERRED_LANGUAGE="es"
SMOKE_QUIZ_OVERRIDE_LABEL="Edge Smoke Quiz Override ${FORWARD_CORRELATION_ID}"
SMOKE_QUIZ_RUNTIME_BASE_URL="http://host.docker.internal:7100"
SMOKE_GENERATE_MAX_ATTEMPTS="8"
SMOKE_GENERATE_RETRY_DELAY_SECONDS="2"
SMOKE_QUIZ_SETTLE_SECONDS="5"
SMOKE_WF05_WORDPASS_CATEGORY_ID="26"
SMOKE_WF05_WORDPASS_DIFFICULTY="20"
SMOKE_WF05_WORDPASS_PROCESS_COUNT="2"
SMOKE_WF05_WORDPASS_MOBILE_MAX_ATTEMPTS="12"
SMOKE_AI_TARGET_HOST="host.docker.internal"
SMOKE_AI_TARGET_PROTOCOL="http"
SMOKE_AI_TARGET_PORT="7002"
SMOKE_AI_TARGET_LABEL="Edge Smoke AI Target ${FORWARD_CORRELATION_ID}"
SMOKE_AI_IDLE_MAX_ATTEMPTS="30"
SMOKE_AI_IDLE_RETRY_SECONDS="2"
SMOKE_EVENT_BASE_TS="$(date +%s)000"
SMOKE_EVENT_SECOND_TS="$((SMOKE_EVENT_BASE_TS + 50000))"
SMOKE_EVENT_SYNC_PAYLOAD="{\"events\":[{\"gameId\":\"edge-smoke-quiz-${FORWARD_CORRELATION_ID}\",\"gameType\":\"quiz\",\"categoryId\":\"ciencia\",\"categoryName\":\"Ciencia\",\"language\":\"es\",\"outcome\":\"WON\",\"score\":90,\"durationSeconds\":120,\"timestamp\":${SMOKE_EVENT_BASE_TS}},{\"gameId\":\"edge-smoke-wordpass-${FORWARD_CORRELATION_ID}\",\"gameType\":\"wordpass\",\"categoryId\":\"historia\",\"categoryName\":\"Historia\",\"language\":\"es\",\"outcome\":\"LOST\",\"score\":30,\"durationSeconds\":75,\"timestamp\":${SMOKE_EVENT_SECOND_TS}}]}"

build_request_args() {
  local method="$1"
  local url="$2"
  local auth_mode="$3"
  local body="${4-}"

  local auth_header=()
  local forwarded_headers=(
    -H "x-correlation-id: $FORWARD_CORRELATION_ID"
  )

  if [[ "$auth_mode" == "valid" ]]; then
    auth_header=(-H "Authorization: Bearer $EDGE_API_TOKEN")
    forwarded_headers+=(
      -H "x-dev-firebase-uid: $FORWARD_DEV_FIREBASE_UID"
      -H "x-api-key: $FORWARD_API_KEY"
    )
  fi

  if [[ -n "$body" ]]; then
    curl -sS -X "$method" "${auth_header[@]}" "${forwarded_headers[@]}" -H "Content-Type: application/json" -d "$body" "$url"
  else
    curl -sS -X "$method" "${auth_header[@]}" "${forwarded_headers[@]}" "$url"
  fi
}

request_with_status() {
  local method="$1"
  local url="$2"
  local auth_mode="$3"
  local body="${4-}"

  local auth_header=()
  local forwarded_headers=(
    -H "x-correlation-id: $FORWARD_CORRELATION_ID"
  )

  if [[ "$auth_mode" == "valid" ]]; then
    auth_header=(-H "Authorization: Bearer $EDGE_API_TOKEN")
    forwarded_headers+=(
      -H "x-dev-firebase-uid: $FORWARD_DEV_FIREBASE_UID"
      -H "x-api-key: $FORWARD_API_KEY"
    )
  fi

  if [[ -n "$body" ]]; then
    curl -sS -w '\n%{http_code}' -X "$method" "${auth_header[@]}" "${forwarded_headers[@]}" -H "Content-Type: application/json" -d "$body" "$url"
  else
    curl -sS -w '\n%{http_code}' -X "$method" "${auth_header[@]}" "${forwarded_headers[@]}" "$url"
  fi
}

url_encode() {
  node -e 'process.stdout.write(encodeURIComponent(process.argv[1]));' "$1"
}

get_json_field() {
  local payload="$1"
  local path="$2"

  printf '%s' "$payload" | node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(0, "utf8"));
let current = data;
for (const segment of process.argv[1].split(".")) {
  current = current?.[segment];
}
if (typeof current === "undefined") {
  console.error(`Missing JSON field ${process.argv[1]}`);
  process.exit(1);
}
if (current !== null && typeof current === "object") {
  process.stdout.write(JSON.stringify(current));
} else {
  process.stdout.write(String(current ?? ""));
}
' "$path"
}

collect_history_ids_in_window() {
  local payload="$1"
  local started_at="$2"
  local finished_at="$3"
  local expected_count="$4"

  printf '%s' "$payload" | node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(0, "utf8"));
const startedAt = Date.parse(process.argv[1]);
const finishedAt = Date.parse(process.argv[2]);
const expectedCount = Number(process.argv[3]);
const items = Array.isArray(data.items) ? data.items : [];
const matching = items.filter((item) => {
  const createdAt = Date.parse(item?.createdAt ?? "");
  return Number.isFinite(createdAt) && createdAt >= startedAt && createdAt <= finishedAt;
});
if (matching.length < expectedCount) {
  console.error(`Expected at least ${expectedCount} history items in process window, got ${matching.length}`);
  process.exit(1);
}
const ids = matching.slice(0, expectedCount).map((item) => String(item?.id ?? "")).filter((id) => id.length > 0);
if (ids.length < expectedCount) {
  console.error(`Expected ${expectedCount} persisted ids in process window, got ${ids.length}`);
  process.exit(1);
}
process.stdout.write(ids.join(","));
' "$started_at" "$finished_at" "$expected_count"
}

expect_mobile_generate_matches_created_ids() {
  local attempts="$1"
  local created_ids_csv="$2"
  local category_id="$3"
  local attempt=1

  while (( attempt <= attempts )); do
    local response
    response="$(request_with_status "POST" "http://localhost:7005/v1/mobile/games/wordpass/generate" "valid" "{\"language\":\"es\",\"categoryId\":\"$category_id\",\"numQuestions\":3}")"
    local status="${response##*$'\n'}"
    local payload="${response%$'\n'*}"

    if [[ "$status" != "200" ]]; then
      if [[ "$status" == "422" || "$status" == "502" || "$status" == "503" ]]; then
        if (( attempt == attempts )); then
          echo "Unexpected transient status for POST http://localhost:7005/v1/mobile/games/wordpass/generate during traceability check after $attempts attempts: last_status=$status"
          exit 1
        fi

        echo "Retrying mobile word-pass generate traceability check after transient status $status (attempt $attempt/$attempts)" >&2
        sleep "$SMOKE_GENERATE_RETRY_DELAY_SECONDS"
        ((attempt++))
        continue
      fi

      echo "Unexpected status for POST http://localhost:7005/v1/mobile/games/wordpass/generate during traceability check: expected=200 got=$status"
      exit 1
    fi

    if printf '%s' "$payload" | node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(0, "utf8"));
const expectedIds = new Set(process.argv[1].split(",").filter(Boolean));
if (String(data.gameType ?? "") !== "word-pass") {
  console.error(`Unexpected gameType in mobile traceability check: got=${String(data.gameType ?? "")}`);
  process.exit(1);
}
const generatedId = String(data.generated?.id ?? "");
if (!generatedId) {
  console.error("Missing generated.id in mobile traceability check");
  process.exit(1);
}
if (!expectedIds.has(generatedId)) {
  process.exit(2);
}
' "$created_ids_csv"; then
      return 0
    fi

    local exit_code=$?
    if [[ "$exit_code" != "2" ]]; then
      exit "$exit_code"
    fi

    if (( attempt == attempts )); then
      echo "Mobile generate did not surface any freshly persisted word-pass id after $attempts attempts"
      exit 1
    fi

    echo "Retrying mobile word-pass generate traceability check (attempt $attempt/$attempts)" >&2
    ((attempt++))
  done
}

expect_json_fields_with_retry() {
  local attempts="$1"
  local method="$2"
  local url="$3"
  local auth_mode="$4"
  local body="$5"
  shift 5

  local attempt=1
  while (( attempt <= attempts )); do
    local response
    response="$(request_with_status "$method" "$url" "$auth_mode" "$body")"
    local status="${response##*$'\n'}"
    local payload="${response%$'\n'*}"

    if [[ "$status" == "200" || "$status" == "201" ]]; then
      printf '%s' "$payload" | node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(0, "utf8"));
for (let index = 1; index < process.argv.length; index += 2) {
  const path = process.argv[index].split(".");
  const expected = process.argv[index + 1];
  let current = data;
  for (const segment of path) {
    current = current?.[segment];
  }
  const actual = String(current ?? "");
  if (expected === "__NONEMPTY__") {
    if (actual.length === 0) {
      console.error(`Unexpected JSON field ${process.argv[index]}: expected non-empty value`);
      process.exit(1);
    }
    continue;
  }
  if (expected === "__NULL__") {
    if (current !== null) {
      console.error(`Unexpected JSON field ${process.argv[index]}: expected null got=${actual}`);
      process.exit(1);
    }
    continue;
  }
  if (actual !== expected) {
    console.error(`Unexpected JSON field ${process.argv[index]}: expected=${expected} got=${actual}`);
    process.exit(1);
  }
}
' "$@"
      return 0
    fi

    if [[ "$status" != "422" && "$status" != "502" && "$status" != "503" ]]; then
      echo "Unexpected status for $method $url (auth=$auth_mode): expected 200/201 got=$status"
      exit 1
    fi

    if (( attempt == attempts )); then
      echo "Unexpected transient status for $method $url (auth=$auth_mode) after $attempts attempts: last_status=$status"
      exit 1
    fi

    echo "Retrying $method $url after transient status $status (attempt $attempt/$attempts)" >&2
    sleep "$SMOKE_GENERATE_RETRY_DELAY_SECONDS"
    ((attempt++))
  done
}

request_generation_process_with_retry() {
  local attempts="$1"
  local url="$2"
  local body="$3"
  local label="$4"

  local attempt=1
  while (( attempt <= attempts )); do
    local response
    response="$(request_with_status "POST" "$url" "none" "$body")"
    local status="${response##*$'\n'}"
    local payload="${response%$'\n'*}"

    if [[ "$status" != "201" ]]; then
      echo "Unexpected status for POST $url: expected=201 got=$status"
      exit 1
    fi

    local created
    local duplicates
    created="$(get_json_field "$payload" "task.created")"
    duplicates="$(get_json_field "$payload" "task.duplicates")"

    if (( created + duplicates >= 1 )); then
      printf '%s\n201' "$payload"
      return 0
    fi

    if (( attempt == attempts )); then
      echo "Expected $label process to produce at least one stored or duplicate item after $attempts attempts, got created=$created duplicates=$duplicates"
      exit 1
    fi

    echo "Retrying $label process generation after empty failed batch (attempt $attempt/$attempts)" >&2
    sleep "$SMOKE_GENERATE_RETRY_DELAY_SECONDS"
    ((attempt++))
  done
}

expect_json_fields() {
  local method="$1"
  local url="$2"
  local auth_mode="$3"
  local body="$4"
  shift 4

  local response
  response="$(request_with_status "$method" "$url" "$auth_mode" "$body")"
  local status="${response##*$'\n'}"
  local payload="${response%$'\n'*}"

  if [[ "$status" != "200" ]]; then
    echo "Unexpected status for $method $url (auth=$auth_mode): expected=200 got=$status"
    exit 1
  fi

  printf '%s' "$payload" | node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(0, "utf8"));
for (let index = 1; index < process.argv.length; index += 2) {
  const path = process.argv[index].split(".");
  const expected = process.argv[index + 1];
  let current = data;
  for (const segment of path) {
    current = current?.[segment];
  }
  const actual = String(current ?? "");
  if (expected === "__NONEMPTY__") {
    if (actual.length === 0) {
      console.error(`Unexpected JSON field ${process.argv[index]}: expected non-empty value`);
      process.exit(1);
    }
    continue;
  }
  if (expected === "__NULL__") {
    if (current !== null) {
      console.error(`Unexpected JSON field ${process.argv[index]}: expected null got=${actual}`);
      process.exit(1);
    }
    continue;
  }
  if (actual !== expected) {
    console.error(`Unexpected JSON field ${process.argv[index]}: expected=${expected} got=${actual}`);
    process.exit(1);
  }
}
' "$@"
}

expect_status() {
  local expected="$1"
  local method="$2"
  local url="$3"
  local auth_mode="$4"
  local body="${5-}"

  local auth_header=()
  local forwarded_headers=(
    -H "x-correlation-id: $FORWARD_CORRELATION_ID"
  )

  if [[ "$auth_mode" == "valid" ]]; then
    auth_header=(-H "Authorization: Bearer $EDGE_API_TOKEN")
    forwarded_headers+=(
      -H "x-dev-firebase-uid: $FORWARD_DEV_FIREBASE_UID"
      -H "x-api-key: $FORWARD_API_KEY"
    )
  fi

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
  local forwarded_headers=(
    -H "x-correlation-id: $FORWARD_CORRELATION_ID"
  )

  if [[ "$auth_mode" == "valid" ]]; then
    auth_header=(-H "Authorization: Bearer $EDGE_API_TOKEN")
    forwarded_headers+=(
      -H "x-dev-firebase-uid: $FORWARD_DEV_FIREBASE_UID"
      -H "x-api-key: $FORWARD_API_KEY"
    )
  fi

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

wait_for_ai_engine_generation_idle() {
  local attempt=1

  while (( attempt <= SMOKE_AI_IDLE_MAX_ATTEMPTS )); do
    if node -e '
const url = process.argv[1];
(async()=>{
  try {
    const res = await fetch(url);
    if (res.status !== 200) {
      process.exit(1);
    }
    const data = await res.json();
    const startupStatus = String(data?.startup?.status ?? "unknown");
    const capacity = data?.dependencies?.generation_capacity ?? {};
    const active = Number(capacity?.active ?? -1);
    const queued = Number(capacity?.queued ?? -1);
    const interactiveQueued = Number(capacity?.interactive_queued ?? -1);
    if (startupStatus === "ready" && active === 0 && queued === 0 && interactiveQueued === 0) {
      process.exit(0);
    }
    process.exit(1);
  } catch {
    process.exit(1);
  }
})();
' "http://localhost:7001/health"; then
      return 0
    fi

    if (( attempt == SMOKE_AI_IDLE_MAX_ATTEMPTS )); then
      echo "ai-engine generation capacity did not become idle after $SMOKE_AI_IDLE_MAX_ATTEMPTS attempts"
      exit 1
    fi

    echo "Waiting for ai-engine generation capacity to become idle (attempt $attempt/$SMOKE_AI_IDLE_MAX_ATTEMPTS)" >&2
    sleep "$SMOKE_AI_IDLE_RETRY_SECONDS"
    ((attempt++))
  done
}

warm_quiz_generation_runtime() {
  echo "Warming quiz generation runtime before edge smoke..." >&2

  local attempt=1
  while (( attempt <= SMOKE_GENERATE_MAX_ATTEMPTS )); do
    local generate_response
    generate_response="$(request_with_status "POST" "http://localhost:7100/games/generate" "none" '{"categoryId":"9","difficultyPercentage":60,"itemCount":1}')"
    local generate_status="${generate_response##*$'\n'}"

    if [[ "$generate_status" == "200" || "$generate_status" == "201" ]]; then
      break
    fi

    if (( attempt == SMOKE_GENERATE_MAX_ATTEMPTS )); then
      echo "Quiz direct warm-up remained cold after $SMOKE_GENERATE_MAX_ATTEMPTS attempts; continuing to authoritative smoke checks." >&2
      break
    fi

    echo "Retrying quiz direct warm-up after transient status $generate_status (attempt $attempt/$SMOKE_GENERATE_MAX_ATTEMPTS)" >&2
    sleep "$SMOKE_GENERATE_RETRY_DELAY_SECONDS"
    ((attempt++))
  done

  sleep "$SMOKE_QUIZ_SETTLE_SECONDS"

  attempt=1
  while (( attempt <= SMOKE_GENERATE_MAX_ATTEMPTS )); do
    local process_response
    process_response="$(request_with_status "POST" "http://localhost:7100/games/generate/process/wait" "none" '{"categoryId":"9","difficultyPercentage":60,"count":3}')"
    local process_status="${process_response##*$'\n'}"
    local process_payload="${process_response%$'\n'*}"

    if [[ "$process_status" == "201" ]]; then
      local created
      local duplicates
      created="$(get_json_field "$process_payload" "task.created")"
      duplicates="$(get_json_field "$process_payload" "task.duplicates")"
      if (( created + duplicates >= 1 )); then
        return 0
      fi
    fi

    if (( attempt == SMOKE_GENERATE_MAX_ATTEMPTS )); then
      echo "Quiz process warm-up remained cold after $SMOKE_GENERATE_MAX_ATTEMPTS attempts; continuing to authoritative smoke checks." >&2
      return 0
    fi

    echo "Retrying quiz process warm-up after cold batch (attempt $attempt/$SMOKE_GENERATE_MAX_ATTEMPTS)" >&2
    sleep "$SMOKE_GENERATE_RETRY_DELAY_SECONDS"
    ((attempt++))
  done
}

wait_for_ai_engine_generation_idle
warm_quiz_generation_runtime

docker compose -f "$COMPOSE_FILE" up -d --build
trap 'docker compose -f "$COMPOSE_FILE" down' EXIT

sleep 8

expect_status "200" "GET" "http://localhost:7005/v1/mobile/games/quiz/random?language=es" "none"
expect_status "200" "GET" "http://localhost:7005/health" "valid"
expect_status "401" "GET" "http://localhost:7005/v1/mobile/player/profile" "none"
expect_status "200" "GET" "http://localhost:7005/v1/mobile/player/profile" "valid"
expect_status "400" "PUT" "http://localhost:7005/v1/mobile/player/profile" "valid" '{"displayName":"","preferredLanguage":"e"}'
expect_json_fields "PUT" "http://localhost:7005/v1/mobile/player/profile" "valid" "{\"displayName\":\"$SMOKE_PROFILE_DISPLAY_NAME\",\"preferredLanguage\":\"$SMOKE_PROFILE_PREFERRED_LANGUAGE\"}" "profile.playerId" "__NONEMPTY__" "profile.displayName" "$SMOKE_PROFILE_DISPLAY_NAME" "profile.preferredLanguage" "$SMOKE_PROFILE_PREFERRED_LANGUAGE" "profile.createdAt" "__NONEMPTY__" "profile.updatedAt" "__NONEMPTY__" "stats.totalGames" "0" "stats.wins" "0" "stats.losses" "0" "stats.draws" "0" "stats.averageScore" "0" "stats.totalScore" "0" "stats.totalPlayTimeSeconds" "0" "stats.lastPlayedAt" "__NULL__"
expect_json_fields "GET" "http://localhost:7005/v1/mobile/player/profile" "valid" "" "profile.playerId" "__NONEMPTY__" "profile.displayName" "$SMOKE_PROFILE_DISPLAY_NAME" "profile.preferredLanguage" "$SMOKE_PROFILE_PREFERRED_LANGUAGE" "profile.createdAt" "__NONEMPTY__" "profile.updatedAt" "__NONEMPTY__" "stats.totalGames" "0" "stats.wins" "0" "stats.losses" "0" "stats.draws" "0" "stats.averageScore" "0" "stats.totalScore" "0" "stats.totalPlayTimeSeconds" "0" "stats.lastPlayedAt" "__NULL__"
expect_json_fields "POST" "http://localhost:7005/v1/mobile/games/events" "valid" "$SMOKE_EVENT_SYNC_PAYLOAD" "synced" "2" "message" "Synced 2 game event(s)" "stats.totalGames" "2" "stats.wins" "1" "stats.losses" "1" "stats.draws" "0" "stats.averageScore" "60" "stats.totalScore" "120" "stats.totalPlayTimeSeconds" "195" "stats.lastPlayedAt" "$SMOKE_EVENT_SECOND_TS"
expect_json_fields "GET" "http://localhost:7005/v1/mobile/player/profile" "valid" "" "stats.totalGames" "2" "stats.wins" "1" "stats.losses" "1" "stats.draws" "0" "stats.averageScore" "60" "stats.totalScore" "120" "stats.totalPlayTimeSeconds" "195" "stats.lastPlayedAt" "$SMOKE_EVENT_SECOND_TS"
expect_json_fields "POST" "http://localhost:7005/v1/mobile/games/events" "valid" "$SMOKE_EVENT_SYNC_PAYLOAD" "synced" "0" "message" "Synced 0 game event(s)" "stats.totalGames" "2" "stats.wins" "1" "stats.losses" "1" "stats.draws" "0" "stats.averageScore" "60" "stats.totalScore" "120" "stats.totalPlayTimeSeconds" "195" "stats.lastPlayedAt" "$SMOKE_EVENT_SECOND_TS"
expect_status "200" "GET" "http://localhost:7005/v1/mobile/games/quiz/random?language=es" "valid"
expect_status "200" "GET" "http://localhost:7005/v1/mobile/games/wordpass/random?language=es" "valid"
expect_status "200" "GET" "http://localhost:7005/v1/backoffice/users/leaderboard?limit=5" "valid"
expect_status "200" "GET" "http://localhost:7005/v1/backoffice/monitor/stats" "valid"
expect_json_fields "PUT" "http://localhost:7005/v1/backoffice/service-targets/microservice-quiz" "valid" "{\"baseUrl\":\"$SMOKE_QUIZ_RUNTIME_BASE_URL\",\"label\":\"$SMOKE_QUIZ_OVERRIDE_LABEL\"}" "service" "microservice-quiz" "source" "override" "baseUrl" "$SMOKE_QUIZ_RUNTIME_BASE_URL" "label" "$SMOKE_QUIZ_OVERRIDE_LABEL" "updatedAt" "__NONEMPTY__"
expect_status "200" "GET" "http://localhost:7005/v1/backoffice/services/microservice-quiz/catalogs" "valid"
expect_json_fields "DELETE" "http://localhost:7005/v1/backoffice/service-targets/microservice-quiz" "valid" "" "service" "microservice-quiz" "source" "env" "baseUrl" "$SMOKE_QUIZ_RUNTIME_BASE_URL" "label" "__NULL__" "updatedAt" "__NULL__"
expect_json_fields "PUT" "http://localhost:7005/v1/backoffice/ai-engine/target" "valid" "{\"host\":\"$SMOKE_AI_TARGET_HOST\",\"protocol\":\"$SMOKE_AI_TARGET_PROTOCOL\",\"port\":$SMOKE_AI_TARGET_PORT,\"label\":\"$SMOKE_AI_TARGET_LABEL\"}" "source" "override" "host" "$SMOKE_AI_TARGET_HOST" "protocol" "$SMOKE_AI_TARGET_PROTOCOL" "port" "$SMOKE_AI_TARGET_PORT" "label" "$SMOKE_AI_TARGET_LABEL" "llamaBaseUrl" "http://$SMOKE_AI_TARGET_HOST:$SMOKE_AI_TARGET_PORT/v1/completions" "envLlamaBaseUrl" "__NONEMPTY__" "updatedAt" "__NONEMPTY__"
expect_json_fields "GET" "http://localhost:7005/v1/backoffice/ai-engine/target" "valid" "" "source" "override" "host" "$SMOKE_AI_TARGET_HOST" "protocol" "$SMOKE_AI_TARGET_PROTOCOL" "port" "$SMOKE_AI_TARGET_PORT" "label" "$SMOKE_AI_TARGET_LABEL" "llamaBaseUrl" "http://$SMOKE_AI_TARGET_HOST:$SMOKE_AI_TARGET_PORT/v1/completions" "envLlamaBaseUrl" "__NONEMPTY__" "updatedAt" "__NONEMPTY__"
expect_json_fields "DELETE" "http://localhost:7005/v1/backoffice/ai-engine/target" "valid" "" "source" "env" "label" "__NULL__" "envLlamaBaseUrl" "__NONEMPTY__" "llamaBaseUrl" "__NONEMPTY__" "updatedAt" "__NULL__"
expect_status "400" "POST" "http://localhost:7100/games/generate" "none" '{}'
expect_json_fields_with_retry "$SMOKE_GENERATE_MAX_ATTEMPTS" "POST" "http://localhost:7100/games/generate" "none" '{"categoryId":"9","difficultyPercentage":60,"itemCount":1}' "gameType" "quiz" "generated" "__NONEMPTY__"
quiz_history_before_response="$(request_with_status "GET" "http://localhost:7100/games/history?limit=1&page=1&pageSize=1&categoryId=9&status=created" "none")"
quiz_history_before_status="${quiz_history_before_response##*$'\n'}"
quiz_history_before_payload="${quiz_history_before_response%$'\n'*}"
if [[ "$quiz_history_before_status" != "200" ]]; then
  echo "Unexpected status for GET http://localhost:7100/games/history before quiz process generation: expected=200 got=$quiz_history_before_status"
  exit 1
fi
quiz_history_before_total="$(get_json_field "$quiz_history_before_payload" "total")"
quiz_process_response="$(request_generation_process_with_retry "$SMOKE_GENERATE_MAX_ATTEMPTS" "http://localhost:7100/games/generate/process/wait" '{"categoryId":"9","difficultyPercentage":60,"count":3}' "quiz")"
quiz_process_status="${quiz_process_response##*$'\n'}"
quiz_process_payload="${quiz_process_response%$'\n'*}"
if [[ "$quiz_process_status" != "201" ]]; then
  echo "Unexpected status for POST http://localhost:7100/games/generate/process/wait: expected=201 got=$quiz_process_status"
  exit 1
fi
quiz_process_created="$(get_json_field "$quiz_process_payload" "task.created")"
quiz_process_duplicates="$(get_json_field "$quiz_process_payload" "task.duplicates")"
quiz_history_after_response="$(request_with_status "GET" "http://localhost:7100/games/history?limit=1&page=1&pageSize=1&categoryId=9&status=created" "none")"
quiz_history_after_status="${quiz_history_after_response##*$'\n'}"
quiz_history_after_payload="${quiz_history_after_response%$'\n'*}"
if [[ "$quiz_history_after_status" != "200" ]]; then
  echo "Unexpected status for GET http://localhost:7100/games/history after quiz process generation: expected=200 got=$quiz_history_after_status"
  exit 1
fi
quiz_history_after_total="$(get_json_field "$quiz_history_after_payload" "total")"
if (( quiz_history_after_total != quiz_history_before_total + quiz_process_created )); then
  echo "Unexpected quiz history growth after process generation: before=$quiz_history_before_total created=$quiz_process_created after=$quiz_history_after_total"
  exit 1
fi
expect_json_fields "GET" "http://localhost:7100/games/models/random?count=1&categoryId=9" "none" "" "gameType" "quiz" "requested" "1" "returned" "1" "items" "__NONEMPTY__"
wordpass_history_before_response="$(request_with_status "GET" "http://localhost:7101/games/history?limit=1&page=1&pageSize=1&categoryId=$SMOKE_WF05_WORDPASS_CATEGORY_ID&status=created" "none")"
wordpass_history_before_status="${wordpass_history_before_response##*$'\n'}"
wordpass_history_before_payload="${wordpass_history_before_response%$'\n'*}"
if [[ "$wordpass_history_before_status" != "200" ]]; then
  echo "Unexpected status for GET http://localhost:7101/games/history before word-pass process generation: expected=200 got=$wordpass_history_before_status"
  exit 1
fi
wordpass_history_before_total="$(get_json_field "$wordpass_history_before_payload" "total")"
wordpass_process_response="$(request_generation_process_with_retry "$SMOKE_GENERATE_MAX_ATTEMPTS" "http://localhost:7101/games/generate/process/wait" "{\"categoryId\":\"$SMOKE_WF05_WORDPASS_CATEGORY_ID\",\"difficultyPercentage\":$SMOKE_WF05_WORDPASS_DIFFICULTY,\"count\":$SMOKE_WF05_WORDPASS_PROCESS_COUNT}" "word-pass")"
wordpass_process_status="${wordpass_process_response##*$'\n'}"
wordpass_process_payload="${wordpass_process_response%$'\n'*}"
if [[ "$wordpass_process_status" != "201" ]]; then
  echo "Unexpected status for POST http://localhost:7101/games/generate/process/wait: expected=201 got=$wordpass_process_status"
  exit 1
fi
wordpass_process_created="$(get_json_field "$wordpass_process_payload" "task.created")"
wordpass_process_duplicates="$(get_json_field "$wordpass_process_payload" "task.duplicates")"
wordpass_process_started_at="$(get_json_field "$wordpass_process_payload" "task.startedAt")"
wordpass_process_finished_at="$(get_json_field "$wordpass_process_payload" "task.finishedAt")"
wordpass_history_after_response="$(request_with_status "GET" "http://localhost:7101/games/history?limit=1&page=1&pageSize=1&categoryId=$SMOKE_WF05_WORDPASS_CATEGORY_ID&status=created" "none")"
wordpass_history_after_status="${wordpass_history_after_response##*$'\n'}"
wordpass_history_after_payload="${wordpass_history_after_response%$'\n'*}"
if [[ "$wordpass_history_after_status" != "200" ]]; then
  echo "Unexpected status for GET http://localhost:7101/games/history after word-pass process generation: expected=200 got=$wordpass_history_after_status"
  exit 1
fi
wordpass_history_after_total="$(get_json_field "$wordpass_history_after_payload" "total")"
if (( wordpass_history_after_total != wordpass_history_before_total + wordpass_process_created )); then
  echo "Unexpected word-pass history growth after process generation: before=$wordpass_history_before_total created=$wordpass_process_created after=$wordpass_history_after_total"
  exit 1
fi
wordpass_history_window_response="$(request_with_status "GET" "http://localhost:7101/games/history?limit=50&page=1&pageSize=50&categoryId=$SMOKE_WF05_WORDPASS_CATEGORY_ID&status=created" "none")"
wordpass_history_window_status="${wordpass_history_window_response##*$'\n'}"
wordpass_history_window_payload="${wordpass_history_window_response%$'\n'*}"
if [[ "$wordpass_history_window_status" != "200" ]]; then
  echo "Unexpected status for GET http://localhost:7101/games/history window scan: expected=200 got=$wordpass_history_window_status"
  exit 1
fi
wordpass_created_ids_csv="$(collect_history_ids_in_window "$wordpass_history_window_payload" "$wordpass_process_started_at" "$wordpass_process_finished_at" "$wordpass_process_created")"
expect_mobile_generate_matches_created_ids "$SMOKE_WF05_WORDPASS_MOBILE_MAX_ATTEMPTS" "$wordpass_created_ids_csv" "$SMOKE_WF05_WORDPASS_CATEGORY_ID"
expect_status "400" "POST" "http://localhost:7005/v1/mobile/games/quiz/generate" "valid" '{"language":"es"}'
expect_status "400" "POST" "http://localhost:7005/v1/mobile/games/wordpass/generate" "valid" '{"language":"es"}'
expect_json_fields_with_retry "$SMOKE_GENERATE_MAX_ATTEMPTS" "POST" "http://localhost:7005/v1/mobile/games/quiz/generate" "valid" '{"language":"es","categoryId":"9","numQuestions":3}' "gameType" "quiz" "generated" "__NONEMPTY__"
expect_json_fields_with_retry "$SMOKE_GENERATE_MAX_ATTEMPTS" "POST" "http://localhost:7005/v1/mobile/games/wordpass/generate" "valid" '{"language":"es","categoryId":"9","numQuestions":3}' "gameType" "word-pass" "generated" "__NONEMPTY__"
expect_status_any "200,400,401,422,502" "POST" "http://localhost:7005/v1/backoffice/users/events/manual" "valid" '{"eventType":"quiz","outcome":"won"}'

echo "Edge smoke OK (auth + profile/deferred-sync + quiz AI generation persistence + word-pass mobile consumption after refresh + service and AI routing override/rollback + GET + POST + critical forwarding headers)"
