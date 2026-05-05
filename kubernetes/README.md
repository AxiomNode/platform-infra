# AxiomNode Kubernetes Infrastructure

Last updated: 2026-05-03.

## Purpose

Kubernetes manifests and deployment tooling for the AxiomNode platform, using **Kustomize** with base + overlay pattern.

## Scope

`dev` runtime is local-first (Docker Compose) and does not use automatic Kubernetes deployment.

## Directory Structure

```
kubernetes/
├── base/                          # Shared manifests (all environments)
│   ├── kustomization.yaml         # Root kustomization
│   ├── namespace.yaml
│   ├── ai-engine/                 # AI engine (api, stats, cache, llama)
│   ├── microservice-quizz/        # Quiz game service + PostgreSQL
│   ├── microservice-wordpass/     # WordPass game service + PostgreSQL
│   ├── microservice-users/        # Users service + PostgreSQL + Firebase
│   ├── api-gateway/               # API Gateway
│   ├── bff-mobile/                # BFF for mobile clients
│   ├── bff-backoffice/            # BFF for backoffice
│   └── backoffice/                # Backoffice frontend (nginx)
└── overlays/
    ├── dev/                       # Legacy/optional k8s dev overlay (no automatic deploy)
    ├── stg/                       # k3s VPS — staging (active remote target)
    └── prod/                      # Cloud managed — production
```

## Environments

| Environment | Cluster | Ingress | Database | Namespace |
|---|---|---|---|---|
| **dev** | Local Docker Compose | Local ports (no public ingress) | Local PostgreSQL containers | N/A |
| **stg** | k3s (VPS 8c/32GB) | Traefik IngressRoute | PostgreSQL StatefulSet | `axiomnode-stg` |
| **prod** | Cloud (EKS/GKE/AKS) | Nginx Ingress + TLS | Managed (RDS/Cloud SQL) | `axiomnode-prod` |

## Quick Start

### 1. Run local dev stack

```bash
./scripts/dev-local-stack.sh up cpu
```

### 2. Setup k3s (stg)

```bash
# On the VPS
sudo ./scripts/setup-k3s.sh
```

### 3. Create Secrets

```bash
# Create a secrets file (not committed to git)
cp secrets/dev.env.example secrets/dev.env
# Edit with real values, then seal
./scripts/seal-secrets.sh dev
```

For production overlays, add sealed manifests under `kubernetes/overlays/prod/sealed-secrets/`
and list them in `kubernetes/overlays/prod/sealed-secrets/kustomization.yaml`.

### 4. Deploy

```bash
# Required for private GHCR pulls when using scripts/deploy.sh manually
export GHCR_PULL_USERNAME=<github-username>
export GHCR_PULL_TOKEN=<token-with-read-packages>

# Deploy to staging
./scripts/deploy.sh stg

# Deploy to production
./scripts/deploy.sh prod
```

### 5. Run Migrations

```bash
./scripts/migrate-db.sh stg
```

## Services

| Service | Image | Port | Resources (base) |
|---|---|---|---|
| microservice-quizz-api | `ghcr.io/axiomnode/microservice-quizz-api` | 7100 | 250m-1 / 256-512Mi |
| microservice-wordpass-api | `ghcr.io/axiomnode/microservice-wordpass-api` | 7100 | 250m-1 / 256-512Mi |
| microservice-users-api | `ghcr.io/axiomnode/microservice-users-api` | 7100 | 250m-1 / 256-512Mi |
| api-gateway | `ghcr.io/axiomnode/api-gateway` | 7005 | 200m-1 / 256-512Mi |
| bff-mobile | `ghcr.io/axiomnode/bff-mobile` | 7010 | 100m-500m / 128-256Mi |
| bff-backoffice | `ghcr.io/axiomnode/bff-backoffice` | 7011 | 200m-1 / 256-512Mi |
| backoffice | `ghcr.io/axiomnode/backoffice` | 80 | 50m-200m / 64-128Mi |

`ai-engine` remains available in `kubernetes/base/ai-engine`, and the split-runtime resources (`ai-engine-api`, `ai-engine-stats`, `ai-engine-cache`) are also available through `kubernetes/base/ai-engine-runtime`. The default `stg` overlay now deploys the runtime services in-cluster while expecting only the llama.cpp server to live on an external workstation. When you need the old fully in-cluster staging topology for smoke tests or benchmarking, render `kubernetes/overlays/stg-with-ai-engine` explicitly.

## Runtime routing persistence

- `bff-backoffice` mounts a small PVC named `bff-backoffice-routing-state` and stores runtime routing overrides at `/var/lib/axiomnode/bff-backoffice/routing-state.json`.
- `bff-backoffice` also stores shared ai-engine destination presets in the same persisted runtime state file.
- `api-gateway` mounts a small PVC named `api-gateway-routing-state` and stores legacy live ai-engine target overrides at `/var/lib/axiomnode/api-gateway/routing-state.json`.
- `ai-engine-api` mounts a small PVC named `ai-engine-api-runtime-state` and stores the active llama target override at `/var/lib/axiomnode/ai-engine-api/llama-target-state.json`.
- This keeps backoffice service-target overrides and the active llama target alive across pod recreations, not just process restarts.
- Environment overlays set `ALLOWED_ROUTING_TARGET_HOSTS` so both BFF and gateway only accept approved internal services, private subnets, and approved environment domains.

## CI/CD

- **Build & Push** (`.github/workflows/build-push.yaml`): Detects changed services, builds Docker images, pushes to GHCR.
- **Deploy** (`.github/workflows/deploy.yaml`): Triggered after successful build on `main` or manually. Current automatic target is `stg`. Automatic deploys render manifests with immutable image tags from the triggering build run; manual deploys keep the environment tags and perform forced restarts when needed.

### Covered automatic rollout chain

The current automatic GHCR-to-k3s staging chain covers:

- `api-gateway`
- `bff-mobile`
- `bff-backoffice`
- `backoffice`
- `ai-engine-api`
- `ai-engine-stats`
- `microservice-quizz`
- `microservice-wordpass`
- `microservice-users`

For these services, the intended behavior is:

1. service repo push to `main`
2. service repo validation succeeds
3. service repo dispatches `platform-infra` build workflow
4. image is published to GHCR
5. staging rollout runs automatically against `axiomnode-stg`

`mobile-app` is outside this chain. The external llama.cpp server is also outside this chain because it still runs on a workstation in the split staging topology.

### Immutable deployment behavior

Automatic staging deploys do not rely on mutable `stg` tags as the authoritative artifact reference. The deploy workflow rewrites the rendered overlay to use the immutable short-SHA images produced by the triggering build run.

This provides:

- clearer rollback targeting
- stronger traceability
- less ambiguity during incident review

### Manual deployment behavior

Manual deploys continue to support environment tags and explicit rollout restart behavior. This is useful for controlled operations and production promotion where the operator wants environment semantics rather than workflow-run immutability.

### Required GitHub Secrets

| Secret | Description |
|---|---|
| `CROSS_REPO_READ_TOKEN` | Fine-grained PAT with `Contents: Read` for all AxiomNode source/dependency repos used in matrix builds |
| `GHCR_PULL_USERNAME` | GitHub username used by cluster deploy jobs to create the GHCR imagePullSecret |
| `GHCR_PULL_TOKEN` | GitHub token (classic PAT recommended) with at least `read:packages` and `repo` (if packages are private) |
| `K3S_HOST` | VPS IP address |
| `K3S_USER` | SSH user for VPS |
| `K3S_SSH_KEY` | SSH private key for VPS |

`GITHUB_TOKEN` is provided automatically by GitHub Actions and is used for pushing images to GHCR in the build workflow.

## Prod Features

- **HPA**: Auto-scaling for api-gateway and bff-mobile (2-6 replicas)
- **PDB**: Pod Disruption Budgets ensure availability during updates
- **TLS**: cert-manager + Let's Encrypt for HTTPS
- **Managed DB**: StatefulSets removed; DATABASE_URL secrets point to external endpoints

## Current Capacity Notes

- `stg` now runs `api-gateway`, `bff-mobile`, `bff-backoffice`, and `backoffice` with at least 2 replicas where interactive backoffice traffic benefits from it.
- `api-gateway` and `bff-backoffice` base resource envelopes were increased after moving `ai-engine` off-cluster, so the VPS can absorb heavier backoffice monitoring and admin traffic without running on the previous tighter CPU/memory ceilings.
