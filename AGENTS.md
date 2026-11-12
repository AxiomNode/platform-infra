# AGENTS

## Repo purpose
Infrastructure and deployment orchestration repo for images, manifests, and environment overlays.

## Key paths
- kubernetes/: base and env overlays
- environments/: compose integration environments
- terraform/: infra-as-code modules
- .github/workflows/: validate, build-push, deploy workflows

## Local commands
- Validate manifests and overlays before commit.
- Use repo workflows for image build/publish/deploy orchestration.

## CI/CD notes
- Service repos dispatch build-push here on push to main.
- `build-push.yaml` is dispatch-only (from a service repo or by hand) and publishes images to GHCR.
- `deploy.yaml` is manual-only: the k3s host it targeted no longer exists, so nothing deploys automatically.

## LLM editing rules
- Do not drift overlay values without documenting rationale.
- Keep workflow inputs/secrets names consistent.
- Update docs when deployment policy changes.
