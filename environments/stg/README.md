# Stg Environment

Last updated: 2026-11-14.

## Purpose

Staging environment definitions used for pre-production validation.

## Scope

## Runtime model

- Target cluster: Kubernetes (k3s) on the staging VPS (SSH target `<k3s-user>@<k3s-host>`, the `K3S_USER`/`K3S_HOST` secrets). That host no longer exists; the definitions below describe what a manual deploy would apply.
- Public ingress domains:
	- `https://axiomnode-backoffice.amksandbox.cloud`
	- `https://axiomnode-gateway.amksandbox.cloud`
- Namespace: `axiomnode-stg`.
- Default staging overlay deploys `ai-engine-api`, `ai-engine-stats`, and `ai-engine-cache` in-cluster. Only the llama.cpp server is expected to run on an external workstation when using the split topology.

## CI/CD behavior

- Service repos on `main` dispatch image builds to `platform-infra`.
- `platform-infra` builds/pushes `stg` tags to GHCR (`build-push.yaml`, dispatch-only).
- `deploy.yaml` is manual-only (`workflow_dispatch`): nothing deploys automatically after a build. A manual dispatch applies `kubernetes/overlays/stg`, which includes `ai-engine-api` and `ai-engine-stats`.
- Manual deploys can still switch to `kubernetes/overlays/stg-with-ai-engine` by dispatching `deploy.yaml` with `include_ai_engine=true` when you deliberately want llama running in-cluster as well.
- Deployment keeps services healthy by:
	- forcing rollout restart for updated tags,
	- waiting for rollout completion,
	- checking available replicas against desired replicas.

## Optional ai-engine canary

- `scripts/ai-engine-stg-canary.sh` works against the default staging overlay for `ai-engine-api` and `ai-engine-stats`.
- In the split topology, only the llama.cpp endpoint remains external; validate that target separately through the configured llama runtime destination.
