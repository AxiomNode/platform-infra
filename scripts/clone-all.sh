#!/usr/bin/env bash
# clone-all.sh - Clone every public AxiomNode repository next to platform-infra
# using the local directory names the Dockerfiles and compose files expect.
#
# Usage (from platform-infra/):
#   ./scripts/clone-all.sh            # clone missing repos, skip existing ones
#   ./scripts/clone-all.sh --no-ai    # skip ai-engine (not needed for the core demo)
#   GIT_BASE=git@github.com:AxiomNode ./scripts/clone-all.sh   # clone over SSH
#
# Two repositories are cloned into a directory whose name differs from the
# GitHub repository name, because the service Dockerfiles COPY from these paths:
#   AxiomNode/microservice-word-pass -> microservice-wordpass/
#   AxiomNode/Backoffice             -> backoffice/
set -euo pipefail

GIT_BASE="${GIT_BASE:-https://github.com/AxiomNode}"
WORKSPACE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INCLUDE_AI=1

for arg in "$@"; do
  case "$arg" in
    --no-ai) INCLUDE_AI=0 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

# "<github repo>:<local directory>"
REPOS=(
  "contracts-and-schemas:contracts-and-schemas"
  "shared-sdk-client:shared-sdk-client"
  "api-gateway:api-gateway"
  "bff-mobile:bff-mobile"
  "bff-backoffice:bff-backoffice"
  "microservice-quizz:microservice-quizz"
  "microservice-word-pass:microservice-wordpass"
  "microservice-users:microservice-users"
  "Backoffice:backoffice"
)
if [[ "$INCLUDE_AI" -eq 1 ]]; then
  REPOS+=("ai-engine:ai-engine")
fi

echo "Workspace: $WORKSPACE"
for entry in "${REPOS[@]}"; do
  repo="${entry%%:*}"
  dir="${entry##*:}"
  target="$WORKSPACE/$dir"

  if [[ -d "$target/.git" ]]; then
    echo "  = $dir (already cloned)"
    continue
  fi

  if [[ "$repo" != "$dir" && -d "$WORKSPACE/$repo/.git" ]]; then
    echo "  ! Found $repo/ but the build expects $dir/." >&2
    echo "    Rename it: mv \"$WORKSPACE/$repo\" \"$target\"" >&2
    echo "    (on case-insensitive filesystems rename via a temporary name)" >&2
    exit 1
  fi

  echo "  + $repo -> $dir"
  git -c core.longpaths=true clone --quiet "$GIT_BASE/$repo.git" "$target"
done

echo "Done. Next: docker compose -f compose.demo.yml up -d --build (see docs/RUN-LOCALLY.md)"
