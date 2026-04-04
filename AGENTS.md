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
- Automatic deploy policy currently targets dev.

## LLM editing rules
- Do not drift overlay values without documenting rationale.
- Keep workflow inputs/secrets names consistent.
- Update docs when deployment policy changes.
