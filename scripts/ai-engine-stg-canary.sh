#!/usr/bin/env bash
set -euo pipefail

SSH_HOST="${SSH_HOST:-sebss@amksandbox.cloud}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/axiomnode_k3s_ci}"
NAMESPACE="${NAMESPACE:-axiomnode-stg}"
POD_NAME="${POD_NAME:-ai-engine-canary}"
GAME_TYPE="${GAME_TYPE:-quiz}"
QUERY="${QUERY:-fotosintesis}"
LANGUAGE="${LANGUAGE:-es}"
CATEGORY_ID="${CATEGORY_ID:-17}"
DIFFICULTY_PERCENTAGE="${DIFFICULTY_PERCENTAGE:-50}"
NUM_QUESTIONS="${NUM_QUESTIONS:-2}"
LETTERS="${LETTERS:-A,B,C,D,E,F,G,H,I,J,L,M,N,O,P,R,S,T,V,Z}"
USE_CACHE="${USE_CACHE:-false}"
FORCE_REFRESH="${FORCE_REFRESH:-true}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-1800}"
BUSY_RETRIES="${BUSY_RETRIES:-12}"
BUSY_SLEEP_SECONDS="${BUSY_SLEEP_SECONDS:-10}"
CAPTURE_DIAGNOSTICS="${CAPTURE_DIAGNOSTICS:-true}"
DIAGNOSTICS_SINCE="${DIAGNOSTICS_SINCE:-20m}"

cat <<REMOTE | ssh -o BatchMode=yes -o IdentitiesOnly=yes -i "$SSH_KEY" "$SSH_HOST" 'bash -s'
set -euo pipefail
NS=${NAMESPACE@Q}
POD=${POD_NAME@Q}
GAME_TYPE=${GAME_TYPE@Q}
QUERY=${QUERY@Q}
LANGUAGE=${LANGUAGE@Q}
CATEGORY_ID=${CATEGORY_ID@Q}
DIFFICULTY_PERCENTAGE=${DIFFICULTY_PERCENTAGE@Q}
NUM_QUESTIONS=${NUM_QUESTIONS@Q}
LETTERS=${LETTERS@Q}
USE_CACHE=${USE_CACHE@Q}
FORCE_REFRESH=${FORCE_REFRESH@Q}
TIMEOUT_SECONDS=${TIMEOUT_SECONDS@Q}
BUSY_RETRIES=${BUSY_RETRIES@Q}
BUSY_SLEEP_SECONDS=${BUSY_SLEEP_SECONDS@Q}
CAPTURE_DIAGNOSTICS=${CAPTURE_DIAGNOSTICS@Q}
DIAGNOSTICS_SINCE=${DIAGNOSTICS_SINCE@Q}

API_KEY=
CORRELATION_ID="canary-$(date +%Y%m%d%H%M%S)-$$"

case "\$GAME_TYPE" in
  quiz)
    ENDPOINT="/generate/quiz?query=\$QUERY&language=\$LANGUAGE&category_id=\$CATEGORY_ID&difficulty_percentage=\$DIFFICULTY_PERCENTAGE&num_questions=\$NUM_QUESTIONS&use_cache=\$USE_CACHE&force_refresh=\$FORCE_REFRESH"
    ;;
  word-pass)
    ENDPOINT="/generate/word-pass?query=\$QUERY&language=\$LANGUAGE&category_id=\$CATEGORY_ID&difficulty_percentage=\$DIFFICULTY_PERCENTAGE&letters=\$LETTERS&use_cache=\$USE_CACHE&force_refresh=\$FORCE_REFRESH"
    ;;
  *)
    echo "Unsupported GAME_TYPE: \$GAME_TYPE" >&2
    exit 1
    ;;
esac

API_KEY=\$(k3s kubectl -n "\$NS" get secret ai-engine-api-secret -o jsonpath='{.data.AI_ENGINE_GAMES_API_KEY}' | base64 -d)

k3s kubectl -n "\$NS" delete pod "\$POD" --ignore-not-found >/dev/null 2>&1 || true

cat >"/tmp/\${POD}.yaml" <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: \${POD}
  namespace: \${NS}
spec:
  restartPolicy: Never
  containers:
    - name: runner
      image: python:3.11-slim
      command: ["python", "-u", "-c"]
      args:
        - |
          import json
          import time
          from urllib.error import HTTPError, URLError
          from urllib.request import Request, urlopen

          api_key = \${API_KEY@Q}
          url = \${ENDPOINT@Q}
          correlation_id = \${CORRELATION_ID@Q}
          timeout_seconds = int(\${TIMEOUT_SECONDS@Q})
          busy_retries = int(\${BUSY_RETRIES@Q})
          busy_sleep_seconds = int(\${BUSY_SLEEP_SECONDS@Q})
          attempts = 0
          started = time.perf_counter()
          status = None
          body = ""

          def fetch_stats():
            request = Request(
              "http://ai-engine-api:8001/monitor/stats",
              headers={"X-API-Key": api_key},
            )
            with urlopen(request, timeout=30) as response:
              payload = json.loads(response.read().decode("utf-8", "replace"))
            return {
              "generation_capacity": payload.get("generation_capacity"),
              "counters": payload.get("counters"),
            }

          before_stats = fetch_stats()
          after_stats = before_stats

          while True:
              attempts += 1
              try:
                  request = Request(
                    f"http://ai-engine-api:8001{url}",
                    headers={"X-API-Key": api_key, "X-Correlation-ID": correlation_id},
                    method="POST",
                  )
                  with urlopen(request, timeout=timeout_seconds) as response:
                      status = response.status
                      body = response.read().decode("utf-8", "replace")
              except HTTPError as exc:
                  status = exc.code
                  body = exc.read().decode("utf-8", "replace")
              except (URLError, TimeoutError) as exc:
                  status = 0
                  body = str(exc)

              if status != 503 or attempts > busy_retries:
                  break

              time.sleep(busy_sleep_seconds)

              after_stats = fetch_stats()

          print(json.dumps({
              "game_type": \${GAME_TYPE@Q},
              "query": \${QUERY@Q},
              "correlation_id": correlation_id,
              "attempts": attempts,
              "status_code": status,
              "latency_ms": round((time.perf_counter() - started) * 1000, 2),
                "stats_before": before_stats,
                "stats_after": after_stats,
              "preview": body[:2000].replace("\\n", " "),
          }, ensure_ascii=False), flush=True)
YAML

k3s kubectl apply -f "/tmp/\${POD}.yaml" >/dev/null
k3s kubectl -n "\$NS" wait --for=condition=Ready pod/"\$POD" --timeout=120s >/dev/null || true
k3s kubectl -n "\$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/"\$POD" --timeout="\${TIMEOUT_SECONDS}s" >/dev/null || true
k3s kubectl -n "\$NS" logs "\$POD"
RESULT=\$?

if [[ "\$CAPTURE_DIAGNOSTICS" == "true" ]]; then
  echo "--- DIAGNOSTICS: API CORRELATION ---"
  k3s kubectl -n "\$NS" logs deploy/ai-engine-api --since="\$DIAGNOSTICS_SINCE" 2>/dev/null | grep "\$CORRELATION_ID" || true
  echo "--- DIAGNOSTICS: API UPSTREAM ERRORS ---"
  k3s kubectl -n "\$NS" logs deploy/ai-engine-api --since="\$DIAGNOSTICS_SINCE" 2>/dev/null | grep -E "upstream request error|upstream timeout|request failed" | tail -n 40 || true
  echo "--- DIAGNOSTICS: LLAMA PODS ---"
  k3s kubectl -n "\$NS" get pods -l app.kubernetes.io/name=ai-engine-llama -o wide || true
  echo "--- DIAGNOSTICS: LLAMA DESCRIBE ---"
  k3s kubectl -n "\$NS" describe pod -l app.kubernetes.io/name=ai-engine-llama | tail -n 80 || true
fi

k3s kubectl -n "\$NS" delete pod "\$POD" --ignore-not-found >/dev/null 2>&1 || true
exit \$RESULT
REMOTE