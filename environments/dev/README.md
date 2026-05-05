# Dev Environment

Last updated: 2026-05-03.

## Purpose

Development environment definitions and local-only runtime assets.

## Scope

## Distribution goal

`dev` is local-first: all services run in containers on the developer machine.
No remote Kubernetes deployment is required for daily development.

## Full local stack

Use the platform-infra script to start the complete stack:

```bash
./scripts/dev-local-stack.sh up cpu
```

Alternative profile:

```bash
./scripts/dev-local-stack.sh up gpu
```

Operational commands:

```bash
./scripts/dev-local-stack.sh status
./scripts/dev-local-stack.sh logs api-gateway
./scripts/dev-local-stack.sh down
```

The script starts:

- `ai-engine` (cache + llama + stats + api)
- `microservice-quizz` (api + db)
- `microservice-wordpass` (api + db)
- `microservice-users` (api + db)
- edge stack (`api-gateway`, `bff-mobile`, `bff-backoffice`, `backoffice`)

All `dev` inter-service communication stays local (`localhost` / `host.docker.internal`).

## Edge integration

- `docker-compose.edge-integration.yml`: starts backoffice + api-gateway + bff-mobile + bff-backoffice for integrated local testing.
