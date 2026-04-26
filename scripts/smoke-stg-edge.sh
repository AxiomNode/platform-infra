#!/usr/bin/env bash
set -euo pipefail

BACKOFFICE_BASE="${BACKOFFICE_BASE:-https://axiomnode-backoffice.amksandbox.cloud}"
GATEWAY_BASE="${GATEWAY_BASE:-https://axiomnode-gateway.amksandbox.cloud}"
EDGE_TOKEN="${EDGE_API_TOKEN:-}"
SMOKE_TARGET_DEPLOYS="${SMOKE_TARGET_DEPLOYS:-all}"
SMOKE_ERROR_RATE_WARN_THRESHOLD="${SMOKE_ERROR_RATE_WARN_THRESHOLD:-0.05}"
SMOKE_LATENCY_WARN_MS="${SMOKE_LATENCY_WARN_MS:-250}"
SMOKE_MIN_SAMPLE_SIZE="${SMOKE_MIN_SAMPLE_SIZE:-50}"
SMOKE_QUIZ_FAILURE_RATIO_WARN_THRESHOLD="${SMOKE_QUIZ_FAILURE_RATIO_WARN_THRESHOLD:-0.95}"

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
WARNINGS=()
FAILURES=()

fetch_edge_token() {
  local config_body
  config_body="$(curl --max-time 20 -fsS "${BACKOFFICE_BASE}/config.js")"
  printf '%s' "$config_body" | sed -n 's/.*VITE_EDGE_API_TOKEN: "\([^"]*\)".*/\1/p'
}

record_pass() {
  local name="$1"
  local detail="$2"
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'PASS | %s | %s\n' "$name" "$detail"
}

record_warn() {
  local name="$1"
  local detail="$2"
  WARN_COUNT=$((WARN_COUNT + 1))
  WARNINGS+=("${name}: ${detail}")
  printf 'WARN | %s | %s\n' "$name" "$detail"
}

record_fail() {
  local name="$1"
  local detail="$2"
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILURES+=("${name}: ${detail}")
  printf 'FAIL | %s | %s\n' "$name" "$detail"
}

target_includes() {
  local deploy="$1"
  if [[ "$SMOKE_TARGET_DEPLOYS" == "all" ]]; then
    return 0
  fi

  [[ " ${SMOKE_TARGET_DEPLOYS} " == *" ${deploy} "* ]]
}

should_check_quiz() {
  target_includes "api-gateway" \
    || target_includes "bff-mobile" \
    || target_includes "bff-backoffice" \
    || target_includes "microservice-quizz-api"
}

should_check_wordpass() {
  target_includes "api-gateway" \
    || target_includes "bff-mobile" \
    || target_includes "bff-backoffice" \
    || target_includes "microservice-wordpass-api"
}

should_check_gateway_metrics() {
  target_includes "api-gateway"
}

should_check_bff_backoffice_metrics() {
  target_includes "bff-backoffice"
}

should_check_bff_mobile_metrics() {
  target_includes "bff-mobile"
}

should_check_users_metrics() {
  target_includes "microservice-users-api"
}

request() {
  local method="$1"
  local url="$2"
  local auth_mode="$3"
  local body="${4-}"
  local response_file
  response_file="$(mktemp)"

  local auth_args=()
  if [[ "$auth_mode" == "bearer" ]]; then
    auth_args=(-H "authorization: Bearer ${EDGE_TOKEN}")
  fi

  local curl_args=(
    --max-time 30
    -sS
    -o "$response_file"
    -w '%{http_code} %{time_total}'
    -X "$method"
  )

  if [[ -n "$body" ]]; then
    curl_args+=("${auth_args[@]}" -H 'content-type: application/json' -d "$body" "$url")
  else
    curl_args+=("${auth_args[@]}" "$url")
  fi

  local meta
  meta="$(curl "${curl_args[@]}")"
  local code="${meta%% *}"
  local time_total="${meta##* }"
  local preview
  preview="$(head -c 220 "$response_file" | tr '\n' ' ' | tr '\r' ' ')"

  printf '%s\n%s\n%s\n' "$code" "$time_total" "$preview"
  rm -f "$response_file"
}

request_json() {
  local method="$1"
  local url="$2"
  local auth_mode="$3"
  local body="${4-}"
  local response_file
  response_file="$(mktemp)"

  local auth_args=()
  if [[ "$auth_mode" == "bearer" ]]; then
    auth_args=(-H "authorization: Bearer ${EDGE_TOKEN}")
  fi

  local curl_args=(
    --max-time 30
    -sS
    -o "$response_file"
    -w '%{http_code}'
    -X "$method"
  )

  if [[ -n "$body" ]]; then
    curl_args+=("${auth_args[@]}" -H 'content-type: application/json' -d "$body" "$url")
  else
    curl_args+=("${auth_args[@]}" "$url")
  fi

  local code
  code="$(curl "${curl_args[@]}")"
  local payload
  payload="$(cat "$response_file")"
  rm -f "$response_file"

  printf '%s\n%s\n' "$code" "$payload"
}

check_status() {
  local name="$1"
  local method="$2"
  local url="$3"
  local auth_mode="$4"
  local expected_code="$5"
  local body="${6-}"
  local result
  result="$(request "$method" "$url" "$auth_mode" "$body")"
  local code
  code="$(printf '%s\n' "$result" | sed -n '1p')"
  local time_total
  time_total="$(printf '%s\n' "$result" | sed -n '2p')"
  local preview
  preview="$(printf '%s\n' "$result" | sed -n '3p')"

  if [[ "$code" == "$expected_code" ]]; then
    record_pass "$name" "status=${code} time=${time_total}s preview=${preview}"
  else
    record_fail "$name" "expected=${expected_code} got=${code} time=${time_total}s preview=${preview}"
  fi
}

check_degraded_quiz() {
  local random_result
  random_result="$(request GET "${GATEWAY_BASE}/v1/mobile/games/quiz/random?language=es&count=3" none)"
  local random_code
  random_code="$(printf '%s\n' "$random_result" | sed -n '1p')"
  local random_time
  random_time="$(printf '%s\n' "$random_result" | sed -n '2p')"
  local random_preview
  random_preview="$(printf '%s\n' "$random_result" | sed -n '3p')"

  if [[ "$random_code" != "200" ]]; then
    record_fail "quiz-random" "expected=200 got=${random_code} time=${random_time}s preview=${random_preview}"
  elif [[ "$random_preview" == *'"returned":0'* || "$random_preview" == *'"items":[]'* ]]; then
    record_warn "quiz-random" "functional degradation: empty payload time=${random_time}s preview=${random_preview}"
  else
    record_pass "quiz-random" "status=${random_code} time=${random_time}s preview=${random_preview}"
  fi

  local history_result
  history_result="$(request GET "${GATEWAY_BASE}/v1/backoffice/services/microservice-quiz/data?dataset=history&page=1&pageSize=3" bearer)"
  local history_code
  history_code="$(printf '%s\n' "$history_result" | sed -n '1p')"
  local history_time
  history_time="$(printf '%s\n' "$history_result" | sed -n '2p')"
  local history_preview
  history_preview="$(printf '%s\n' "$history_result" | sed -n '3p')"

  if [[ "$history_code" == "200" ]]; then
    record_pass "quiz-history" "status=${history_code} time=${history_time}s preview=${history_preview}"
  else
    record_warn "quiz-history" "backoffice degradation: expected=200 got=${history_code} time=${history_time}s preview=${history_preview}"
  fi
}

check_wordpass_history() {
  local result
  result="$(request GET "${GATEWAY_BASE}/v1/backoffice/services/microservice-wordpass/data?dataset=history&page=1&pageSize=3" bearer)"
  local code
  code="$(printf '%s\n' "$result" | sed -n '1p')"
  local time_total
  time_total="$(printf '%s\n' "$result" | sed -n '2p')"
  local preview
  preview="$(printf '%s\n' "$result" | sed -n '3p')"

  if [[ "$code" == "200" ]]; then
    record_pass "wordpass-history" "status=${code} time=${time_total}s preview=${preview}"
  else
    record_fail "wordpass-history" "expected=200 got=${code} time=${time_total}s preview=${preview}"
  fi
}

check_live_route_warn_only() {
  local name="$1"
  local method="$2"
  local url="$3"
  local auth_mode="$4"
  local expected_code="$5"
  local body="${6-}"
  local result
  result="$(request "$method" "$url" "$auth_mode" "$body")"
  local code
  code="$(printf '%s\n' "$result" | sed -n '1p')"
  local time_total
  time_total="$(printf '%s\n' "$result" | sed -n '2p')"
  local preview
  preview="$(printf '%s\n' "$result" | sed -n '3p')"

  if [[ "$code" == "$expected_code" ]]; then
    record_pass "$name" "status=${code} time=${time_total}s preview=${preview}"
  else
    record_warn "$name" "expected=${expected_code} got=${code} time=${time_total}s preview=${preview}"
  fi
}

analyze_traffic_metrics() {
  local label="$1"
  local url="$2"
  local result
  result="$(request_json GET "$url" bearer)"
  local code
  code="$(printf '%s\n' "$result" | sed -n '1p')"
  local payload
  payload="$(printf '%s\n' "$result" | sed -n '2,$p')"

  if [[ "$code" != "200" ]]; then
    record_fail "$label-health" "expected=200 got=${code}"
    return
  fi

  local analysis
  analysis="$(node -e "const payload=JSON.parse(process.argv[1]); const metrics=payload.metrics ?? {}; const traffic=metrics.traffic ?? metrics; const requests=Number(traffic.requestsReceivedTotal ?? 0); const errors=Number(traffic.errorsTotal ?? 0); const latency=Number(traffic.latencyAvgMs ?? 0); const routeRows=Array.isArray(metrics.requestsByRoute) ? metrics.requestsByRoute : Array.isArray(payload.requestsByRoute) ? payload.requestsByRoute : []; const failingRoutes=routeRows.filter((row)=>Number(row?.statusCode ?? 0) >= 500).sort((a,b)=>Number(b?.total ?? 0)-Number(a?.total ?? 0)).slice(0,3).map((row)=>({method:String(row?.method ?? '?'), route:String(row?.route ?? '?'), statusCode:Number(row?.statusCode ?? 0), total:Number(row?.total ?? 0)})); const hasTraffic=Number.isFinite(requests) && Number.isFinite(errors) && Number.isFinite(latency); const errorRate=requests > 0 ? errors / requests : 0; process.stdout.write(JSON.stringify({hasTraffic, requests, errors, latency, errorRate, failingRoutes}));" "$payload")"
  local has_traffic
  has_traffic="$(node -e "const data=JSON.parse(process.argv[1]); process.stdout.write(String(data.hasTraffic));" "$analysis")"

  if [[ "$has_traffic" != "true" ]]; then
    record_pass "$label-metrics" "no traffic metrics exposed"
    return
  fi

  local requests errors latency error_rate failing_routes
  requests="$(node -e "const data=JSON.parse(process.argv[1]); process.stdout.write(String(data.requests));" "$analysis")"
  errors="$(node -e "const data=JSON.parse(process.argv[1]); process.stdout.write(String(data.errors));" "$analysis")"
  latency="$(node -e "const data=JSON.parse(process.argv[1]); process.stdout.write(String(data.latency));" "$analysis")"
  error_rate="$(node -e "const data=JSON.parse(process.argv[1]); process.stdout.write(String(data.errorRate));" "$analysis")"
  failing_routes="$(node -e "const data=JSON.parse(process.argv[1]); process.stdout.write((data.failingRoutes ?? []).map((row)=>String(row.method)+' '+String(row.route)+' '+String(row.statusCode)+' x'+String(row.total)).join('; '));" "$analysis")"

  local verdict="pass"
  local reasons=()
  if node -e "process.exit(Number(process.argv[1]) >= Number(process.argv[2]) ? 0 : 1)" "$requests" "$SMOKE_MIN_SAMPLE_SIZE"; then
    if node -e "process.exit(Number(process.argv[1]) > Number(process.argv[2]) ? 0 : 1)" "$error_rate" "$SMOKE_ERROR_RATE_WARN_THRESHOLD"; then
      verdict="warn"
      reasons+=("errorRate=${error_rate}")
    fi
    if node -e "process.exit(Number(process.argv[1]) > Number(process.argv[2]) ? 0 : 1)" "$latency" "$SMOKE_LATENCY_WARN_MS"; then
      verdict="warn"
      reasons+=("latencyAvgMs=${latency}")
    fi
  fi

  local summary="requests=${requests} errors=${errors} errorRate=${error_rate} latencyAvgMs=${latency}"
  if [[ -n "$failing_routes" ]]; then
    summary+=" failingRoutes=${failing_routes}"
  fi
  if [[ "$verdict" == "warn" ]]; then
    record_warn "$label-metrics" "${summary} thresholds exceeded: ${reasons[*]}"
  else
    record_pass "$label-metrics" "$summary"
  fi
}

analyze_quiz_generation_metrics() {
  local result
  result="$(request_json GET "${GATEWAY_BASE}/v1/backoffice/services/microservice-quiz/metrics" bearer)"
  local code
  code="$(printf '%s\n' "$result" | sed -n '1p')"
  local payload
  payload="$(printf '%s\n' "$result" | sed -n '2,$p')"

  if [[ "$code" != "200" ]]; then
    record_fail "quiz-generation-metrics" "expected=200 got=${code}"
    return
  fi

  local summary
  summary="$(node -e "const payload=JSON.parse(process.argv[1]); const generation=payload.metrics?.generation ?? {}; const attempts=Number(generation.attemptsTotal ?? 0); const stored=Number(generation.generatedStoredTotal ?? 0); const failed=Number(generation.generatedFailedTotal ?? 0); const ratio=Number(generation.failureRatio ?? (attempts > 0 ? failed / attempts : 0)); process.stdout.write(JSON.stringify({attempts, stored, failed, ratio}));" "$payload")"
  local attempts stored failed ratio
  attempts="$(node -e "const data=JSON.parse(process.argv[1]); process.stdout.write(String(data.attempts));" "$summary")"
  stored="$(node -e "const data=JSON.parse(process.argv[1]); process.stdout.write(String(data.stored));" "$summary")"
  failed="$(node -e "const data=JSON.parse(process.argv[1]); process.stdout.write(String(data.failed));" "$summary")"
  ratio="$(node -e "const data=JSON.parse(process.argv[1]); process.stdout.write(String(data.ratio));" "$summary")"

  if node -e "process.exit(Number(process.argv[1]) >= Number(process.argv[2]) ? 0 : 1)" "$attempts" "$SMOKE_MIN_SAMPLE_SIZE" \
    && node -e "process.exit(Number(process.argv[1]) > Number(process.argv[2]) ? 0 : 1)" "$ratio" "$SMOKE_QUIZ_FAILURE_RATIO_WARN_THRESHOLD"; then
    record_warn "quiz-generation-metrics" "attempts=${attempts} stored=${stored} failed=${failed} failureRatio=${ratio}"
  else
    record_pass "quiz-generation-metrics" "attempts=${attempts} stored=${stored} failed=${failed} failureRatio=${ratio}"
  fi
}

printf 'Staging smoke target: %s | %s\n' "$BACKOFFICE_BASE" "$GATEWAY_BASE"

if [[ -z "$EDGE_TOKEN" ]]; then
  EDGE_TOKEN="$(fetch_edge_token)"
fi

if [[ -z "$EDGE_TOKEN" ]]; then
  echo 'Unable to resolve EDGE_API_TOKEN from backoffice config.js'
  exit 1
fi

check_status "backoffice-root" GET "${BACKOFFICE_BASE}/" none 200
check_status "backoffice-config" GET "${BACKOFFICE_BASE}/config.js" none 200
check_status "gateway-health" GET "${GATEWAY_BASE}/health" none 200
check_status "backoffice-auth-session-no-token" POST "${GATEWAY_BASE}/v1/backoffice/auth/session" none 401 '{}'
check_status "backoffice-services" GET "${GATEWAY_BASE}/v1/backoffice/services" bearer 200
check_status "api-gateway-metrics" GET "${GATEWAY_BASE}/v1/backoffice/services/api-gateway/metrics" bearer 200
check_status "bff-backoffice-metrics" GET "${GATEWAY_BASE}/v1/backoffice/services/bff-backoffice/metrics" bearer 200
check_status "bff-mobile-metrics" GET "${GATEWAY_BASE}/v1/backoffice/services/bff-mobile/metrics" bearer 200
check_status "microservice-users-metrics" GET "${GATEWAY_BASE}/v1/backoffice/services/microservice-users/metrics" bearer 200
check_status "microservice-quiz-metrics" GET "${GATEWAY_BASE}/v1/backoffice/services/microservice-quiz/metrics" bearer 200
check_status "microservice-wordpass-metrics" GET "${GATEWAY_BASE}/v1/backoffice/services/microservice-wordpass/metrics" bearer 200
check_status "ai-engine-api-metrics" GET "${GATEWAY_BASE}/v1/backoffice/services/ai-engine-api/metrics" bearer 200
check_status "ai-engine-stats-metrics" GET "${GATEWAY_BASE}/v1/backoffice/services/ai-engine-stats/metrics" bearer 200
check_status "mobile-categories" GET "${GATEWAY_BASE}/v1/mobile/games/categories?language=es" none 200
check_status "wordpass-random" GET "${GATEWAY_BASE}/v1/mobile/games/wordpass/random?language=es&count=3" none 200
check_status "ai-health" GET "${GATEWAY_BASE}/internal/ai-engine/health" bearer 200

if should_check_gateway_metrics; then
  analyze_traffic_metrics "api-gateway" "${GATEWAY_BASE}/v1/backoffice/services/api-gateway/metrics"
fi

if should_check_bff_backoffice_metrics; then
  analyze_traffic_metrics "bff-backoffice" "${GATEWAY_BASE}/v1/backoffice/services/bff-backoffice/metrics"
fi

if should_check_bff_mobile_metrics; then
  analyze_traffic_metrics "bff-mobile" "${GATEWAY_BASE}/v1/backoffice/services/bff-mobile/metrics"
fi

if should_check_users_metrics; then
  analyze_traffic_metrics "microservice-users" "${GATEWAY_BASE}/v1/backoffice/services/microservice-users/metrics"
fi

if should_check_quiz; then
  analyze_traffic_metrics "microservice-quiz" "${GATEWAY_BASE}/v1/backoffice/services/microservice-quiz/metrics"
  analyze_quiz_generation_metrics
fi

if should_check_wordpass; then
  analyze_traffic_metrics "microservice-wordpass" "${GATEWAY_BASE}/v1/backoffice/services/microservice-wordpass/metrics"
fi

if should_check_quiz; then
  check_degraded_quiz
  check_live_route_warn_only \
    "quiz-generate-live" \
    POST \
    "${GATEWAY_BASE}/v1/mobile/games/quiz/generate" \
    none \
    200 \
    '{"language":"es","categoryId":"9","count":1}'
fi

if should_check_wordpass; then
  check_wordpass_history
  check_live_route_warn_only \
    "wordpass-generate-live" \
    POST \
    "${GATEWAY_BASE}/v1/mobile/games/wordpass/generate" \
    none \
    200 \
    '{"language":"es","categoryId":"9","count":1}'
fi

printf '\nSummary | pass=%s warn=%s fail=%s\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"

if (( FAIL_COUNT > 0 )); then
  printf '%s\n' 'Hard failures:'
  printf ' - %s\n' "${FAILURES[@]}"
  exit 1
fi

if (( WARN_COUNT > 0 )); then
  printf '%s\n' 'Degradations:'
  printf ' - %s\n' "${WARNINGS[@]}"
  exit 2
fi

exit 0
