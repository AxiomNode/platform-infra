# Prod Sealed Secrets

Place production sealed secret manifests in this directory and list them in `kustomization.yaml`.

Recommended naming convention:
- `api-gateway-secret.yaml`
- `backoffice-secret.yaml`
- `microservice-users-db-secret.yaml`

These manifests are expected to contain SealedSecret resources generated for the prod cluster.
