#!/usr/bin/env bash
set -euo pipefail

QUIZ_BASE_URL="${QUIZ_BASE_URL:-http://localhost:7100}"
AI_ENGINE_API_BASE_URL="${AI_ENGINE_API_BASE_URL:-http://localhost:7001}"
WF05_CATEGORY_ID="${WF05_CATEGORY_ID:-9}"
WF05_DIFFICULTY_PERCENTAGE="${WF05_DIFFICULTY_PERCENTAGE:-60}"
WF05_SINGLE_ITEM_COUNT="${WF05_SINGLE_ITEM_COUNT:-1}"
WF05_PROCESS_COUNT="${WF05_PROCESS_COUNT:-3}"
WF05_GENERATE_MAX_ATTEMPTS="${WF05_GENERATE_MAX_ATTEMPTS:-4}"

check_health() {
  local service_name="$1"
  local url="$2"

  local status
  status="$(node -e "(async()=>{try{const r=await fetch('${url}');process.stdout.write(String(r.status));}catch(_){process.stdout.write('ERR');}})();")"

  if [[ "$status" != "200" ]]; then
    echo "Dependency not ready: $service_name at $url (status=$status)"
    echo "Start the minimal WF-05 stack first:"
    echo "  docker compose -f ai-engine/src/docker-compose.yml --profile cpu up -d --build ai-cache llama-server-cpu ai-stats ai-api"
    echo "  docker compose -f microservice-quizz/docker-compose.yml up -d --build"
    exit 1
  fi
}

request_with_status() {
  local method="$1"
  local url="$2"
  local body="${3-}"

  if [[ -n "$body" ]]; then
    curl -sS -w '\n%{http_code}' -X "$method" -H "Content-Type: application/json" -d "$body" "$url"
  else
    curl -sS -w '\n%{http_code}' -X "$method" "$url"
  fi
}

url_encode() {
  node -e 'process.stdout.write(encodeURIComponent(process.argv[1]));' "$1"
}

get_json_field() {
  local payload="$1"
  local path="$2"

  node -e '
const data = JSON.parse(process.argv[1]);
let current = data;
for (const segment of process.argv[2].split(".")) {
  current = current?.[segment];
}
if (typeof current === "undefined") {
  console.error(`Missing JSON field ${process.argv[2]}`);
  process.exit(1);
}
if (current !== null && typeof current === "object") {
  process.stdout.write(JSON.stringify(current));
} else {
  process.stdout.write(String(current ?? ""));
}
' "$payload" "$path"
}

collect_history_ids_in_window() {
  local payload="$1"
  local started_at="$2"
  local finished_at="$3"
  local expected_count="$4"

  node -e '
const data = JSON.parse(process.argv[1]);
const startedAt = Date.parse(process.argv[2]);
const finishedAt = Date.parse(process.argv[3]);
const expectedCount = Number(process.argv[4]);
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
' "$payload" "$started_at" "$finished_at" "$expected_count"
}

expect_random_matches_created_ids() {
  local base_url="$1"
  local game_type="$2"
  local category_id="$3"
  local started_at="$4"
  local finished_at="$5"
  local created_ids_csv="$6"

  local started_at_encoded
  started_at_encoded="$(url_encode "$started_at")"
  local finished_at_encoded
  finished_at_encoded="$(url_encode "$finished_at")"

  local response
  response="$(request_with_status "GET" "$base_url/games/models/random?count=1&categoryId=$category_id&createdAfter=$started_at_encoded&createdBefore=$finished_at_encoded")"
  local status="${response##*$'\n'}"
  local payload="${response%$'\n'*}"

  if [[ "$status" != "200" ]]; then
    echo "Unexpected status for GET $base_url/games/models/random traceability check: expected=200 got=$status"
    exit 1
  fi

  node -e '
const data = JSON.parse(process.argv[1]);
const gameType = process.argv[2];
const expectedIds = new Set(process.argv[3].split(",").filter(Boolean));
if (String(data.gameType ?? "") !== gameType) {
  console.error(`Unexpected gameType in random traceability check: expected=${gameType} got=${String(data.gameType ?? "")}`);
  process.exit(1);
}
if (String(data.returned ?? "") !== "1") {
  console.error(`Expected returned=1 in random traceability check, got=${String(data.returned ?? "")}`);
  process.exit(1);
}
const itemId = String(data.items?.[0]?.id ?? "");
if (!itemId) {
  console.error("Missing items[0].id in random traceability check");
  process.exit(1);
}
if (!expectedIds.has(itemId)) {
  console.error(`Random traceability check returned unexpected id=${itemId}; expected one of ${Array.from(expectedIds).join(",")}`);
  process.exit(1);
}
' "$payload" "$game_type" "$created_ids_csv"
}

expect_status() {
  local expected="$1"
  local method="$2"
  local url="$3"
  local body="${4-}"

  local response
  response="$(request_with_status "$method" "$url" "$body")"
  local status="${response##*$'\n'}"

  if [[ "$status" != "$expected" ]]; then
    echo "Unexpected status for $method $url: expected=$expected got=$status"
    exit 1
  fi
}

expect_json_fields() {
  local method="$1"
  local url="$2"
  local body="$3"
  shift 3

  local response
  response="$(request_with_status "$method" "$url" "$body")"
  local status="${response##*$'\n'}"
  local payload="${response%$'\n'*}"

  if [[ "$status" != "200" && "$status" != "201" ]]; then
    echo "Unexpected status for $method $url: expected 200/201 got=$status"
    exit 1
  fi

  node -e '
const data = JSON.parse(process.argv[1]);
for (let index = 2; index < process.argv.length; index += 2) {
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
  if (actual !== expected) {
    console.error(`Unexpected JSON field ${process.argv[index]}: expected=${expected} got=${actual}`);
    process.exit(1);
  }
}
' "$payload" "$@"
}

expect_json_fields_with_retry() {
  local attempts="$1"
  local method="$2"
  local url="$3"
  local body="$4"
  shift 4

  local attempt=1
  while (( attempt <= attempts )); do
    local response
    response="$(request_with_status "$method" "$url" "$body")"
    local status="${response##*$'\n'}"
    local payload="${response%$'\n'*}"

    if [[ "$status" == "200" || "$status" == "201" ]]; then
      node -e '
const data = JSON.parse(process.argv[1]);
for (let index = 2; index < process.argv.length; index += 2) {
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
  if (actual !== expected) {
    console.error(`Unexpected JSON field ${process.argv[index]}: expected=${expected} got=${actual}`);
    process.exit(1);
  }
}
' "$payload" "$@"
      return 0
    fi

    if [[ "$status" != "422" && "$status" != "502" && "$status" != "503" ]]; then
      echo "Unexpected status for $method $url: expected 200/201 got=$status"
      exit 1
    fi

    if (( attempt == attempts )); then
      echo "Unexpected status for $method $url after $attempts attempts: last_status=$status"
      exit 1
    fi

    echo "Retrying $method $url after transient status $status (attempt $attempt/$attempts)" >&2
    ((attempt++))
  done
}

check_health "ai-engine-api" "$AI_ENGINE_API_BASE_URL/health"
check_health "microservice-quizz" "$QUIZ_BASE_URL/health"

expect_status "400" "POST" "$QUIZ_BASE_URL/games/generate" '{}'
expect_json_fields_with_retry "$WF05_GENERATE_MAX_ATTEMPTS" "POST" "$QUIZ_BASE_URL/games/generate" "{\"categoryId\":\"$WF05_CATEGORY_ID\",\"difficultyPercentage\":$WF05_DIFFICULTY_PERCENTAGE,\"itemCount\":$WF05_SINGLE_ITEM_COUNT}" "gameType" "quiz" "generated" "__NONEMPTY__"

history_before_response="$(request_with_status "GET" "$QUIZ_BASE_URL/games/history?limit=1&page=1&pageSize=1&categoryId=$WF05_CATEGORY_ID&status=created")"
history_before_status="${history_before_response##*$'\n'}"
history_before_payload="${history_before_response%$'\n'*}"
if [[ "$history_before_status" != "200" ]]; then
  echo "Unexpected status for GET $QUIZ_BASE_URL/games/history before generation: expected=200 got=$history_before_status"
  exit 1
fi
history_before_total="$(get_json_field "$history_before_payload" "total")"

process_response="$(request_with_status "POST" "$QUIZ_BASE_URL/games/generate/process/wait" "{\"categoryId\":\"$WF05_CATEGORY_ID\",\"difficultyPercentage\":$WF05_DIFFICULTY_PERCENTAGE,\"count\":$WF05_PROCESS_COUNT}")"
process_status="${process_response##*$'\n'}"
process_payload="${process_response%$'\n'*}"
if [[ "$process_status" != "201" ]]; then
  echo "Unexpected status for POST $QUIZ_BASE_URL/games/generate/process/wait: expected=201 got=$process_status"
  exit 1
fi
process_created="$(get_json_field "$process_payload" "task.created")"
if (( process_created < 1 )); then
  echo "Expected blocking generation process to create at least one item, got created=$process_created"
  exit 1
fi
process_started_at="$(get_json_field "$process_payload" "task.startedAt")"
process_finished_at="$(get_json_field "$process_payload" "task.finishedAt")"

history_after_response="$(request_with_status "GET" "$QUIZ_BASE_URL/games/history?limit=1&page=1&pageSize=1&categoryId=$WF05_CATEGORY_ID&status=created")"
history_after_status="${history_after_response##*$'\n'}"
history_after_payload="${history_after_response%$'\n'*}"
if [[ "$history_after_status" != "200" ]]; then
  echo "Unexpected status for GET $QUIZ_BASE_URL/games/history after generation: expected=200 got=$history_after_status"
  exit 1
fi
history_after_total="$(get_json_field "$history_after_payload" "total")"
if (( history_after_total != history_before_total + process_created )); then
  echo "Unexpected history growth: before=$history_before_total created=$process_created after=$history_after_total"
  exit 1
fi

history_window_response="$(request_with_status "GET" "$QUIZ_BASE_URL/games/history?limit=50&page=1&pageSize=50&categoryId=$WF05_CATEGORY_ID&status=created")"
history_window_status="${history_window_response##*$'\n'}"
history_window_payload="${history_window_response%$'\n'*}"
if [[ "$history_window_status" != "200" ]]; then
  echo "Unexpected status for GET $QUIZ_BASE_URL/games/history window scan: expected=200 got=$history_window_status"
  exit 1
fi
created_ids_csv="$(collect_history_ids_in_window "$history_window_payload" "$process_started_at" "$process_finished_at" "$process_created")"

expect_random_matches_created_ids "$QUIZ_BASE_URL" "quiz" "$WF05_CATEGORY_ID" "$process_started_at" "$process_finished_at" "$created_ids_csv"

echo "WF-05 quiz smoke OK (ai-engine -> quiz generation -> persisted history growth -> exact random traceability)"