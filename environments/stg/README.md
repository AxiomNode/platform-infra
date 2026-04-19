# Stg Environment

Staging environment definitions used for pre-production validation.

## Runtime model

- Target cluster: Kubernetes on `sebss@amksandbox.cloud`.
- Public ingress domains:
	- `https://axiomnode-backoffice.amksandbox.cloud`
	- `https://axiomnode-gateway.amksandbox.cloud`
- Namespace: `axiomnode-stg`.
- Default staging overlay deploys `ai-engine-api`, `ai-engine-stats`, and `ai-engine-cache` in-cluster. Only the llama.cpp server is expected to run on an external workstation when using the split topology.

## CI/CD behavior

- Service repos on `main` dispatch image builds to `platform-infra`.
- `platform-infra` builds/pushes `stg` tags to GHCR.
- Deploy workflow applies `kubernetes/overlays/stg` automatically after successful build.
- `ai-engine-api` and `ai-engine-stats` image builds trigger the default k3s rollout because the runtime services are now part of the default staging overlay.
- Manual deploys can still switch to `kubernetes/overlays/stg-with-ai-engine` by dispatching `deploy.yaml` with `include_ai_engine=true` when you deliberately want llama running in-cluster as well.
- Deployment keeps services healthy by:
	- forcing rollout restart for updated tags,
	- waiting for rollout completion,
	- checking available replicas against desired replicas.

## Optional ai-engine canary

- `scripts/ai-engine-stg-canary.sh` works against the default staging overlay for `ai-engine-api` and `ai-engine-stats`.
- In the split topology, only the llama.cpp endpoint remains external; validate that target separately through the configured llama runtime destination.
