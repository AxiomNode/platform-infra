# Stg Environment

Staging environment definitions used for pre-production validation.

## Runtime model

- Target cluster: Kubernetes on `sebss@amksandbox.cloud`.
- Public ingress domains:
	- `https://axiomnode-backoffice.amksandbox.cloud`
	- `https://axiomnode-gateway.amksandbox.cloud`
- Namespace: `axiomnode-stg`.

## CI/CD behavior

- Service repos on `main` dispatch image builds to `platform-infra`.
- `platform-infra` builds/pushes `stg` tags to GHCR.
- Deploy workflow applies `kubernetes/overlays/stg` automatically after successful build.
- Deployment keeps services healthy by:
	- forcing rollout restart for updated tags,
	- waiting for rollout completion,
	- checking available replicas against desired replicas.
