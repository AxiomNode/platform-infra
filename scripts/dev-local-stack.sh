#!/usr/bin/env bash
# dev-local-stack.sh - Full local development stack for AxiomNode (dev distribution)
# Usage:
#   ./scripts/dev-local-stack.sh demo [ai]       # anyone: compose.demo.yml, no secrets (docs/RUN-LOCALLY.md)
#   ./scripts/dev-local-stack.sh demo-down
#   ./scripts/dev-local-stack.sh up [cpu|gpu]    # maintainers: needs .env.secrets from the private vault
#   ./scripts/dev-local-stack.sh down
#   ./scripts/dev-local-stack.sh status
#   ./scripts/dev-local-stack.sh logs [service]
set -euo pipefail

ACTION="${1:-}"
AI_PROFILE="${2:-cpu}"

usage() {
  echo "Usage: $0 <demo|demo-down|up|down|status|logs> [ai|cpu|gpu|service]"
}

if [[ -z "$ACTION" ]]; then
  usage
  exit 1
fi

# Workspace = directory that contains platform-infra/ and the sibling service clones.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Two local directory names differ from the GitHub repository names because the
# service Dockerfiles COPY from these exact paths (scripts/clone-all.sh creates them):
#   AxiomNode/microservice-word-pass -> microservice-wordpass/
#   AxiomNode/Backoffice             -> backoffice/
WORDPASS_DIR="microservice-wordpass"
BACKOFFICE_DIR="backoffice"

DEMO_COMPOSE="$ROOT_DIR/platform-infra/compose.demo.yml"
AI_ENGINE_COMPOSE="$ROOT_DIR/ai-engine/src/docker-compose.yml"
QUIZZ_COMPOSE="$ROOT_DIR/microservice-quizz/docker-compose.yml"
WORDPASS_COMPOSE="$ROOT_DIR/$WORDPASS_DIR/docker-compose.yml"
USERS_COMPOSE="$ROOT_DIR/microservice-users/docker-compose.yml"
EDGE_COMPOSE="$ROOT_DIR/platform-infra/environments/dev/docker-compose.edge-integration.yml"

required_env_examples=(
  "$ROOT_DIR/ai-engine/src/.env:$ROOT_DIR/ai-engine/src/distributions/dev/windows.env"
  "$ROOT_DIR/microservice-quizz/src/.env:$ROOT_DIR/microservice-quizz/src/.env.example"
  "$ROOT_DIR/$WORDPASS_DIR/src/.env:$ROOT_DIR/$WORDPASS_DIR/src/.env.example"
  "$ROOT_DIR/microservice-users/src/.env:$ROOT_DIR/microservice-users/src/.env.example"
  "$ROOT_DIR/api-gateway/src/.env:$ROOT_DIR/api-gateway/src/.env.example"
  "$ROOT_DIR/bff-mobile/src/.env:$ROOT_DIR/bff-mobile/src/.env.example"
  "$ROOT_DIR/bff-backoffice/src/.env:$ROOT_DIR/bff-backoffice/src/.env.example"
)

required_secrets=(
  "$ROOT_DIR/ai-engine/src/.env.secrets"
  "$ROOT_DIR/microservice-quizz/src/.env.secrets"
  "$ROOT_DIR/$WORDPASS_DIR/src/.env.secrets"
  "$ROOT_DIR/microservice-users/src/.env.secrets"
  "$ROOT_DIR/api-gateway/src/.env.secrets"
  "$ROOT_DIR/bff-mobile/src/.env.secrets"
  "$ROOT_DIR/bff-backoffice/src/.env.secrets"
  "$ROOT_DIR/$BACKOFFICE_DIR/.env.secrets"
)

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "Error: docker CLI is not installed."
    exit 1
  fi

  if ! docker compose version >/dev/null 2>&1; then
    echo "Error: docker compose plugin is required."
    exit 1
  fi

  if ! docker info >/dev/null 2>&1; then
    echo "Error: Docker daemon is not running. Start Docker Desktop/Engine and retry."
    exit 1
  fi
}

# Verify the sibling clones exist under the names the Dockerfiles expect.
# Extra "<github-repo>:<local-dir>" entries can be passed as arguments.
ensure_workspace_layout() {
  local missing=0
  local entry repo dir
  for entry in \
    "contracts-and-schemas:contracts-and-schemas" \
    "shared-sdk-client:shared-sdk-client" \
    "api-gateway:api-gateway" \
    "bff-mobile:bff-mobile" \
    "bff-backoffice:bff-backoffice" \
    "microservice-quizz:microservice-quizz" \
    "microservice-word-pass:$WORDPASS_DIR" \
    "microservice-users:microservice-users" \
    "Backoffice:$BACKOFFICE_DIR" \
    "$@"; do
    repo="${entry%%:*}"
    dir="${entry##*:}"
    if [[ -d "$ROOT_DIR/$dir" ]]; then
      continue
    fi
    missing=1
    if [[ "$repo" != "$dir" && -d "$ROOT_DIR/$repo" ]]; then
      echo "Found $ROOT_DIR/$repo but the Dockerfiles expect $ROOT_DIR/$dir - rename it."
    else
      echo "Missing sibling clone: $ROOT_DIR/$dir (AxiomNode/$repo)"
    fi
  done

  if [[ "$missing" -eq 1 ]]; then
    echo "Run ./scripts/clone-all.sh from platform-infra/ to create the expected layout."
    exit 1
  fi
}

ensure_env_templates() {
  for entry in "${required_env_examples[@]}"; do
    local target="${entry%%:*}"
    local example="${entry##*:}"

    if [[ -f "$target" ]]; then
      continue
    fi

    if [[ ! -f "$example" ]]; then
      echo "Error: missing env template: $example"
      exit 1
    fi

    cp "$example" "$target"
    echo "Created $target from template."
  done
}

ensure_secrets_files() {
  local missing=0
  for secret_file in "${required_secrets[@]}"; do
    if [[ ! -f "$secret_file" ]]; then
      echo "Missing secrets file: $secret_file"
      missing=1
    fi
  done

  if [[ "$missing" -eq 1 ]]; then
    echo ""
    echo "The 'up' action is the maintainer stack: it expects .env.secrets files"
    echo "injected from the private vault."
    echo ""
    echo "Without vault access, run the public demo stack instead (no secrets):"
    echo "  $0 demo        # see platform-infra/docs/RUN-LOCALLY.md"
    echo ""
    exit 1
  fi
}

compose_up() {
  local compose_file="$1"
  shift
  docker compose -f "$compose_file" up -d --build "$@"
}

compose_down() {
  local compose_file="$1"
  docker compose -f "$compose_file" down --remove-orphans
}

compose_ps() {
  local compose_file="$1"
  echo ""
  echo "==> $(basename "$(dirname "$compose_file")")"
  docker compose -f "$compose_file" ps
}

case "$ACTION" in
  demo)
    ensure_docker
    if [[ "${2:-}" == "ai" ]]; then
      ensure_workspace_layout "ai-engine:ai-engine"
      docker compose -f "$DEMO_COMPOSE" --profile ai up -d --build
    else
      ensure_workspace_layout
      docker compose -f "$DEMO_COMPOSE" up -d --build
    fi

    echo ""
    echo "Demo stack is up (see platform-infra/docs/RUN-LOCALLY.md)."
    echo "Backoffice:  http://localhost:7080   (dev login, UID admin-dev-uid)"
    echo "Gateway:     http://localhost:7005/health"
    ;;

  demo-down)
    ensure_docker
    docker compose -f "$DEMO_COMPOSE" --profile ai down --remove-orphans
    ;;

  up)
    ensure_docker
    ensure_workspace_layout "ai-engine:ai-engine"
    ensure_env_templates
    ensure_secrets_files

    if [[ "$AI_PROFILE" != "cpu" && "$AI_PROFILE" != "gpu" ]]; then
      echo "Error: profile must be 'cpu' or 'gpu'."
      exit 1
    fi

    export DISTRIBUTION=dev
    export RELEASE_VERSION=local
    export AI_ENGINE_DISTRIBUTION=dev
    export AI_ENGINE_RELEASE_VERSION=local

    LLAMA_SERVICE="llama-server-$AI_PROFILE"

    echo "[1/5] Starting ai-engine stack ($AI_PROFILE profile)..."
    compose_up "$AI_ENGINE_COMPOSE" --profile "$AI_PROFILE" ai-cache "$LLAMA_SERVICE" ai-stats ai-api

    echo "[2/5] Starting microservice-quizz (api + db)..."
    compose_up "$QUIZZ_COMPOSE"

    echo "[3/5] Starting microservice-wordpass (api + db)..."
    compose_up "$WORDPASS_COMPOSE"

    echo "[4/5] Starting microservice-users (api + db)..."
    compose_up "$USERS_COMPOSE"

    echo "[5/5] Starting edge stack (backoffice + gateway + bffs)..."
    compose_up "$EDGE_COMPOSE"

    echo ""
    echo "Dev local stack is up."
    echo "Backoffice:  http://localhost:7080"
    echo "Gateway:     http://localhost:7005/health"
    echo "AI Stats:    http://localhost:7000/health"
    echo "AI API:      http://localhost:7001/health"
    ;;

  down)
    ensure_docker

    echo "Stopping edge stack..."
    compose_down "$EDGE_COMPOSE" || true

    echo "Stopping microservices..."
    compose_down "$USERS_COMPOSE" || true
    compose_down "$WORDPASS_COMPOSE" || true
    compose_down "$QUIZZ_COMPOSE" || true

    echo "Stopping ai-engine stack..."
    compose_down "$AI_ENGINE_COMPOSE" || true

    echo "Dev local stack stopped."
    ;;

  status)
    ensure_docker
    compose_ps "$AI_ENGINE_COMPOSE" || true
    compose_ps "$QUIZZ_COMPOSE" || true
    compose_ps "$WORDPASS_COMPOSE" || true
    compose_ps "$USERS_COMPOSE" || true
    compose_ps "$EDGE_COMPOSE" || true
    ;;

  logs)
    ensure_docker
    SERVICE="${2:-}"

    if [[ -n "$SERVICE" ]]; then
      docker compose -f "$AI_ENGINE_COMPOSE" -f "$QUIZZ_COMPOSE" -f "$WORDPASS_COMPOSE" -f "$USERS_COMPOSE" -f "$EDGE_COMPOSE" logs -f "$SERVICE"
    else
      echo "Provide a service name for logs, for example:"
      echo "  $0 logs api-gateway"
      exit 1
    fi
    ;;

  *)
    echo "Unknown action: $ACTION"
    usage
    exit 1
    ;;
esac
