# platform-infra

Infrastructure and deployment orchestration for the AxiomNode platform.

## What this repository owns

- Kubernetes base manifests and overlays.
- Environment-specific compose assets.
- Infrastructure validation and deployment automation.
- Cross-repository image build orchestration.

## Repository structure

- `kubernetes/`: base resources + `dev`/`stg`/`prod` overlays.
- `environments/`: compose-based integration environments.
- `terraform/`: infrastructure as code modules.
- `.github/workflows/`: CI/CD workflows.

## CI/CD workflows

- `validate-infra.yml`
	- Trigger: push (`main`, `develop`), pull request, manual dispatch.
	- Purpose: validates required infrastructure directories.

- `build-push.yaml` (Build & Push Docker Images)
	- Trigger: push (`main`, `develop`) and manual dispatch.
	- Purpose: detects changed services (or selected service), checks out source repos, and publishes images to GHCR.
	- Notes:
		- Uses `CROSS_REPO_READ_TOKEN` to access private source repos.
		- Publishes `dev` tags, and on `main` also publishes `stg` and `latest`.

- `deploy.yaml` (Deploy to Kubernetes)
	- Trigger: successful completion of `build-push.yaml` on `main`, or manual dispatch.
	- Current policy: automatic deployment is pinned to `dev` only.
	- Purpose: validates manifests, syncs overlays to k3s, applies manifests, restarts deployments, and waits for rollout.

## Current automation chain

1. A service repo receives a push on `main`.
2. That repo CI dispatches `platform-infra/.github/workflows/build-push.yaml` with a service input.
3. Build/push publishes updated image tags in GHCR.
4. `deploy.yaml` runs and applies changes to `axiomnode-dev`.

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
