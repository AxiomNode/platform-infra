# AxiomNode Kubernetes Infrastructure

Kubernetes manifests and deployment tooling for the AxiomNode platform, using **Kustomize** with base + overlay pattern.

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
    ├── dev/                       # k3s VPS — development
    ├── stg/                       # k3s VPS — staging
    └── prod/                      # Cloud managed — production
```

## Environments

| Environment | Cluster | Ingress | Database | Namespace |
|---|---|---|---|---|
| **dev** | k3s (VPS 8c/32GB) | Traefik IngressRoute | PostgreSQL StatefulSet | `axiomnode-dev` |
| **stg** | k3s (VPS 8c/32GB) | Traefik IngressRoute | PostgreSQL StatefulSet | `axiomnode-stg` |
| **prod** | Cloud (EKS/GKE/AKS) | Nginx Ingress + TLS | Managed (RDS/Cloud SQL) | `axiomnode-prod` |

## Quick Start

### 1. Setup k3s (dev/stg)

```bash
# On the VPS
sudo ./scripts/setup-k3s.sh
```

### 2. Create Secrets

```bash
# Create a secrets file (not committed to git)
cp secrets/dev.env.example secrets/dev.env
# Edit with real values, then seal
./scripts/seal-secrets.sh dev
```

### 3. Deploy

```bash
# Deploy to dev
./scripts/deploy.sh dev

# Deploy to staging
./scripts/deploy.sh stg

# Deploy to production
./scripts/deploy.sh prod
```

### 4. Run Migrations

```bash
./scripts/migrate-db.sh dev
```

## Services

| Service | Image | Port | Resources (base) |
|---|---|---|---|
| ai-engine-api | `ghcr.io/axiomnode/ai-engine-api` | 8001 | 500m-1500m / 2-4Gi |
| ai-engine-stats | `ghcr.io/axiomnode/ai-engine-stats` | 8000 | 250m-500m / 256-512Mi |
| ai-engine-cache | `redis:7-alpine` | 6379 | 100m-250m / 128-256Mi |
| ai-engine-llama | `ghcr.io/ggerganov/llama.cpp:server` | 8080 | 2-4 CPU / 6-10Gi |
| microservice-quizz-api | `ghcr.io/axiomnode/microservice-quizz-api` | 7100 | 250m-1 / 256-512Mi |
| microservice-wordpass-api | `ghcr.io/axiomnode/microservice-wordpass-api` | 7100 | 250m-1 / 256-512Mi |
| microservice-users-api | `ghcr.io/axiomnode/microservice-users-api` | 7100 | 250m-1 / 256-512Mi |
| api-gateway | `ghcr.io/axiomnode/api-gateway` | 7005 | 100m-500m / 128-256Mi |
| bff-mobile | `ghcr.io/axiomnode/bff-mobile` | 7010 | 100m-500m / 128-256Mi |
| bff-backoffice | `ghcr.io/axiomnode/bff-backoffice` | 7011 | 100m-500m / 128-256Mi |
| backoffice | `ghcr.io/axiomnode/backoffice` | 80 | 50m-200m / 64-128Mi |

## CI/CD

- **Build & Push** (`.github/workflows/build-push.yaml`): Detects changed services, builds Docker images, pushes to GHCR.
- **Deploy** (`.github/workflows/deploy.yaml`): Triggered after successful build or manually. Applies Kustomize overlays to the target cluster.

### Required GitHub Secrets

| Secret | Description |
|---|---|
| `CROSS_REPO_READ_TOKEN` | Fine-grained PAT with `Contents: Read` for all AxiomNode source/dependency repos used in matrix builds |
| `GHCR_PULL_USERNAME` | GitHub username used by the cluster to pull private GHCR images |
| `GHCR_PULL_TOKEN` | GitHub token (classic PAT recommended) with at least `read:packages` for `ghcr.io/axiomnode/*` |
| `K3S_HOST` | VPS IP address |
| `K3S_USER` | SSH user for VPS |
| `K3S_SSH_KEY` | SSH private key for VPS |
| `PROD_KUBECONFIG` | Base64-encoded kubeconfig for prod cluster |

## Prod Features

- **HPA**: Auto-scaling for api-gateway, bff-mobile, ai-engine-api (2-6 replicas)
- **PDB**: Pod Disruption Budgets ensure availability during updates
- **TLS**: cert-manager + Let's Encrypt for HTTPS
- **Managed DB**: StatefulSets removed; DATABASE_URL secrets point to external endpoints
