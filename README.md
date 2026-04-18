# platform-infra

Infrastructure and deployment orchestration for the AxiomNode platform.

## What this repository owns

- Kubernetes base manifests and overlays.
- Environment-specific compose assets.
- Infrastructure validation and deployment automation.
- Cross-repository image build orchestration.
- Dev local orchestration for full-stack container runtime.

## Distribution Logic

- `dev`
	- Local-only distribution.
	- Full stack runs via Docker Compose on a developer machine.
	- Service-to-service connections are local (localhost/host.docker.internal).
	- Entry point: `scripts/dev-local-stack.sh`.

- `stg`
	- Remote Kubernetes distribution on `sebss@amksandbox.cloud`.
	- Public domains route through ingress.
	- `ai-engine` is no longer part of the default staging overlay; the cluster expects an optional external workstation target managed at runtime from backoffice.
	- CI/CD auto-deploy target after successful image builds on `main`.

- `prod`
	- Final distribution tier for production scalability.
	- Can run distributed services and external cloud-managed resources (DB, ingress, scaling).
	- Deployment is manual/controlled, not the default automatic target.

## Repository structure

- `kubernetes/`: base resources + `dev`/`stg`/`prod` overlays.
- `environments/`: compose-based integration environments.
- `terraform/`: infrastructure as code modules.
- `.github/workflows/`: CI/CD workflows.

## CI/CD workflows

- `validate-infra.yml`
	- Trigger: push (`main`, `develop`), pull request, manual dispatch.
	- Purpose: validates required infrastructure directories, blocks mutable Kubernetes `:latest` image tags, and renders `dev`/`stg`/`prod` overlays with `kubectl kustomize`.

- `build-push.yaml` (Build & Push Docker Images)
	- Trigger: push (`main`, `develop`) and manual dispatch.
	- Purpose: detects changed services (or selected service), checks out source repos, and publishes images to GHCR.
	- Notes:
		- Uses `CROSS_REPO_READ_TOKEN` to access private source repos.
		- Publishes `dev` tags, and on `main` also publishes `stg`.
		- Optional `publish_prod_tag=true` on manual dispatch adds mutable `prod` tags for controlled production promotion.

- `deploy.yaml` (Deploy to Kubernetes)
	- Trigger: successful completion of `build-push.yaml` on `main`, or manual dispatch.
	- Current policy: automatic deployment is pinned to `stg`.
	- Purpose: validates manifests, renders the selected overlay, applies manifests to k3s, and waits for rollout.
	- Notes:
		- Workflow-driven staging deploys pin changed services to the immutable short-SHA tags produced by the triggering build run.
		- Manual deploys keep the environment tags (`stg`/`prod`) and still force restarts when a mutable tag must be refreshed.
	- Safety: rollout status + available replica checks fail the workflow if services are not healthy.

## Current automation chain

1. A service repo receives a push on `main`.
2. That repo CI dispatches `platform-infra/.github/workflows/build-push.yaml` with a service input.
3. Build/push publishes updated image tags in GHCR.
4. `deploy.yaml` runs and applies changes to `axiomnode-stg`.

## Local Dev Stack

Run all dev services locally with a single script:

```bash
./scripts/dev-local-stack.sh up cpu
```

Useful commands:

```bash
./scripts/dev-local-stack.sh status
./scripts/dev-local-stack.sh logs api-gateway
./scripts/dev-local-stack.sh down
```

## Staging Canary

Run an in-cluster ai-engine canary against staging without port-forwarding, but only when you deliberately deploy the optional in-cluster ai-engine manifests:

```bash
./scripts/ai-engine-stg-canary.sh
```

Useful overrides:

```bash
GAME_TYPE=word-pass QUERY="sistema solar" ./scripts/ai-engine-stg-canary.sh
QUERY="teorema de pitagoras" CATEGORY_ID=19 NUM_QUESTIONS=3 ./scripts/ai-engine-stg-canary.sh
```

## Required secrets in this repository

- `CROSS_REPO_READ_TOKEN`
- `GHCR_PULL_USERNAME`
- `GHCR_PULL_TOKEN`
- `K3S_HOST`
- `K3S_USER`
- `K3S_SSH_KEY`

`GITHUB_TOKEN` is used by the build workflow to publish packages to GHCR.

## Related docs

- `kubernetes/README.md`
- `environments/dev/README.md`
- `environments/stg/README.md`
- `environments/prod/README.md`
