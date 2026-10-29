# Run AxiomNode locally (public demo)

This guide runs the AxiomNode platform on one machine **without any private
credentials**. Every image is built locally from the public repositories, and
the configuration uses only the dummy values committed in each service's
`.env.example` plus the overrides in [`compose.demo.yml`](../compose.demo.yml).

> Maintainers with access to the private vault can keep using
> `scripts/dev-local-stack.sh up`. Everyone else should use the demo stack below.

## Requirements

- Docker Engine 24+ (or Docker Desktop) with the Compose v2 plugin, running.
- Git and a POSIX shell (Linux, macOS, WSL or Git Bash on Windows).
- About 6 GB free disk for images. Internet access for the first build
  (npm packages, base images, and Prisma CLI on first container start).
- Free host ports: `7005`, `7010`, `7011`, `7080`, `7100`-`7102`, `7432`-`7434`
  (plus `7000`-`7002` with the optional AI profile).

## 1. Clone the workspace

All repositories must sit next to each other. Two of them are cloned under a
different local directory name, because the service Dockerfiles `COPY` from
those exact paths:

| GitHub repository                  | Local directory          |
| ---------------------------------- | ------------------------ |
| `AxiomNode/microservice-word-pass` | `microservice-wordpass/` |
| `AxiomNode/Backoffice`             | `backoffice/`            |

The helper script handles this for you:

```bash
mkdir axiomnode && cd axiomnode
git clone https://github.com/AxiomNode/platform-infra.git
cd platform-infra
./scripts/clone-all.sh          # add --no-ai to skip ai-engine
```

Equivalent manual loop:

```bash
cd axiomnode
for pair in contracts-and-schemas shared-sdk-client api-gateway bff-mobile \
            bff-backoffice microservice-quizz microservice-users ai-engine \
            microservice-word-pass:microservice-wordpass Backoffice:backoffice; do
  repo="${pair%%:*}"; dir="${pair##*:}"
  git -c core.longpaths=true clone "https://github.com/AxiomNode/$repo.git" "$dir"
done
```

## 2. Start the core stack (no AI)

From `platform-infra/`:

```bash
docker compose -f compose.demo.yml up -d --build
# or: ./scripts/dev-local-stack.sh demo
```

The first build takes several minutes. Check progress with
`docker compose -f compose.demo.yml ps` until every service is `healthy`.

### Services and ports

| Service                 | URL                              | Notes                                   |
| ----------------------- | -------------------------------- | --------------------------------------- |
| Backoffice (web UI)     | http://localhost:7080            | Dev login, UID `admin-dev-uid`          |
| API gateway             | http://localhost:7005/health     | Public entry point                      |
| bff-mobile              | http://localhost:7010/health     |                                         |
| bff-backoffice          | http://localhost:7011/health     |                                         |
| microservice-quizz      | http://localhost:7100/health     | Postgres on `7432` (`quiz`/`quiz`)      |
| microservice-wordpass   | http://localhost:7101/health     | Postgres on `7433` (`wordpass`/`wordpass`) |
| microservice-users      | http://localhost:7102/health     | Postgres on `7434` (`users`/`users`)    |

### Smoke test

```bash
curl -s http://localhost:7005/health
curl -s http://localhost:7005/v1/mobile/games/categories
curl -s -H "x-dev-firebase-uid: demo-player" http://localhost:7005/v1/mobile/player/profile
```

The categories call returns the built-in catalog (`"source": "local-fallback"`
on the microservices' `/catalogs`) because no AI engine is running.

## 3. Optional: local AI generation (profile `ai`)

Game generation needs the `ai-engine` API plus a llama.cpp server. This is
opt-in because it downloads roughly 1 GB of Python wheels (CPU-only PyTorch)
during the build and a ~90 MB embedding model on first start.

1. Download a small GGUF model (~400 MB) into `ai-engine/src/models/`, for
   example Qwen2.5 0.5B Instruct:

   ```bash
   mkdir -p ../ai-engine/src/models
   curl -L -o ../ai-engine/src/models/qwen2.5-0.5b-instruct-q4_k_m.gguf \
     https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf
   ```

   Any other GGUF file works: set `DEMO_LLAMA_MODEL_FILE=<file name>`. Larger
   models (for example the 3B model used in staging) give much better games.

2. Start the stack with the profile:

   ```bash
   docker compose -f compose.demo.yml --profile ai up -d --build
   # or: ./scripts/dev-local-stack.sh demo ai
   ```

3. Generate and store a game on the quiz microservice (slow on CPU, can take
   minutes), then fetch it through the gateway. The mobile `.../generate`
   endpoints serve games from this stored inventory:

   ```bash
   curl -s -X POST http://localhost:7100/games/generate \
     -H 'content-type: application/json' -d '{"categoryId":"9","itemCount":3}'
   curl -s -X POST http://localhost:7005/v1/mobile/games/quiz/generate \
     -H 'content-type: application/json' -d '{"categoryId":"9"}'
   ```

Extra ports with this profile: ai-stats `7000`, ai-api `7001`, llama.cpp `7002`.

## What works in demo mode

- All services build from source and pass their health checks.
- Gateway -> BFF -> microservice routing, rate limiting, metrics endpoints.
- Game category catalogs (built-in fallback list).
- Postgres persistence for quiz, word-pass and users data (named volumes).
- Backoffice UI with the **dev login** (`VITE_AUTH_MODE=dev`): the default UID
  `admin-dev-uid` is bootstrapped as SuperAdmin, so user/role screens work.
- Mobile endpoints that need a player identity, using the
  `x-dev-firebase-uid: <any-id>` header instead of a Firebase ID token.
- With the `ai` profile: quiz and word-pass generation against a local model.

## What is mocked or not available

| Area | Demo behaviour |
| ---- | -------------- |
| Firebase Auth | Not used. `microservice-users` runs with its existing local-development switch `FIREBASE_STRICT_AUTH=false`, which accepts the `x-dev-firebase-uid` header when no bearer token is sent. Real Google/Firebase sign-in does not work. The Firebase Auth emulator is **not** wired: the service only initialises `firebase-admin` from service-account credentials, so supporting the emulator would need a code change in `microservice-users`. |
| AI engine | Off by default. Microservice generation endpoints return an upstream error, and the mobile game endpoints have no stored games to serve. Enable the `ai` profile to generate them locally. |
| Seed data | Databases start empty. |
| Edge token / admin tokens | `EDGE_API_TOKEN` is empty (no edge auth). Admin tokens are fixed dummy strings such as `demo_gateway_admin_token`. |
| Kubernetes-backed backoffice features | Deployment/rollout panels need a cluster API and show errors or empty states. |
| Observability stack, Sentry, Mobile app | Not part of the demo. The mobile app targets the hosted environments. |
| Published images | Not used. GHCR images are private, so everything is built locally. |

**Never** reuse `FIREBASE_STRICT_AUTH=false` or any value from
`compose.demo.yml` outside a local machine.

## Stop and clean up

```bash
docker compose -f compose.demo.yml --profile ai down        # keep data
docker compose -f compose.demo.yml --profile ai down -v     # also delete databases
```

## Troubleshooting

- **`COPY microservice-wordpass/...` or `backoffice/...` not found**: a repo was
  cloned under its GitHub name. Rename the directory (see step 1) or rerun
  `./scripts/clone-all.sh`, which detects this case.
- **Port already allocated**: another local stack (for example the maintainer
  `dev-local-stack.sh up`) is using the same ports. Stop it first.
- **A microservice keeps restarting**: check `docker compose -f compose.demo.yml
  logs microservice-users`. The first start runs `prisma db push`, which needs
  internet access to fetch the Prisma CLI.
