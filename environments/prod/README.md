# Prod Environment

Production environment definitions and release-hardening assets.

## Runtime model

`prod` is the final distribution tier and can run distributed services with cloud-managed components.

- Cluster: managed Kubernetes (EKS/GKE/AKS).
- Data layer: external managed databases (RDS/Cloud SQL equivalents).
- Traffic: managed ingress + TLS + autoscaling policies.

## Operational intent

- Favor high availability and controlled rollouts.
- Keep `prod` promotion explicit/manual.
- Maintain backward-compatible API behavior against `stg` validation gates.
