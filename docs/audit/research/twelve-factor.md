# 12-Factor App methodology

> Research-agent output for the ALFa AI architecture audit (2026-05-13).
> Read by `audit-agent` to check `/home/operator/alfa-ai/` against upstream guidance.

## Official documentation

- **Primary docs URL:** https://12factor.net/
- **Per-factor pages:**
  - I. Codebase: https://12factor.net/codebase
  - II. Dependencies: https://12factor.net/dependencies
  - III. Config: https://12factor.net/config
  - IV. Backing services: https://12factor.net/backing-services
  - V. Build, release, run: https://12factor.net/build-release-run
  - VI. Processes: https://12factor.net/processes
  - VII. Port binding: https://12factor.net/port-binding
  - VIII. Concurrency: https://12factor.net/concurrency
  - IX. Disposability: https://12factor.net/disposability
  - X. Dev/prod parity: https://12factor.net/dev-prod-parity
  - XI. Logs: https://12factor.net/logs
  - XII. Admin processes: https://12factor.net/admin-processes
- **Source:** original document by Adam Wiggins (Heroku), https://github.com/heroku/12factor.

## Current stable / supported version (as of 2026-05-13)

- The 12-Factor App is a **methodology document**, not a software release. The canonical text on https://12factor.net/ is the same one published by Heroku (Adam Wiggins) in 2011 and revised periodically. There is no version number; methodology has been stable for ~14 years.
- **EOL policy:** N/A — the principles are language-, framework-, and infra-agnostic. Modern interpretations (e.g. "Beyond the Twelve-Factor App" by Kevin Hoffman, 2016) extend it for cloud-native; the core 12 are unchanged.

## Key official best practices

The 12 factors, verbatim from https://12factor.net/:

- **I. Codebase** — *One codebase tracked in revision control, many deploys.* https://12factor.net/codebase
- **II. Dependencies** — *Explicitly declare and isolate dependencies.* https://12factor.net/dependencies
- **III. Config** — *Store config in the environment.* "Env vars are easy to change between deploys without changing any code; unlike config files, there is little chance of them being checked into the code repo accidentally." A 12-factor app's config is granular per-deploy, never grouped into named "environments". https://12factor.net/config
- **IV. Backing services** — *Treat backing services as attached resources.* DB, cache, queue, mail, etc. all reachable via URL/credentials in env, swappable without code change. https://12factor.net/backing-services
- **V. Build, release, run** — *Strictly separate build and run stages.* A release = build + config; the run stage is a stateless execution of an immutable release. https://12factor.net/build-release-run
- **VI. Processes** — *Execute the app as one or more stateless processes.* No filesystem state survives between requests. Sticky sessions = anti-pattern. https://12factor.net/processes
- **VII. Port binding** — *Export services via port binding.* App self-contains an HTTP server (Uvicorn, etc.); reverse proxy is external. https://12factor.net/port-binding
- **VIII. Concurrency** — *Scale out via the process model.* Add more processes (workers/replicas), don't grow a single process. https://12factor.net/concurrency
- **IX. Disposability** — *Maximize robustness with fast startup and graceful shutdown.* Process should boot in seconds and exit cleanly on SIGTERM. https://12factor.net/disposability
- **X. Dev/prod parity** — *Keep development, staging, and production as similar as possible.* Same backing services, same OS-level versions, same deploy tooling. https://12factor.net/dev-prod-parity
- **XI. Logs** — *Treat logs as event streams.* Write to stdout/stderr; let the platform aggregate. Don't write log files in-app. https://12factor.net/logs
- **XII. Admin processes** — *Run admin/management tasks as one-off processes* against the same code + config + release as the long-running processes. https://12factor.net/admin-processes

## Canonical configuration examples

This factor methodology is descriptive, not prescriptive in syntax. The closest "config example" is the rule from Factor III (Config):

> **"A litmus test for whether an app has all config correctly factored out of the code is whether the codebase could be made open source at any moment, without compromising any credentials."**
>
> — https://12factor.net/config

Practical implementation patterns:

- Env vars in `.env.example` (committed) + `.env` (NOT committed, sourced at boot).
- Compose / k8s read env from external sources (`secrets:`, vault).
- Logs via `print()`/stdout, not `RotatingFileHandler` writing to `/var/log/myapp.log`.
- Build artifact = container image with a SHA tag; release = image + env vars; run = `docker compose up`/k8s deployment.

## Common pitfalls / gotchas

- **Named environments (`dev`/`staging`/`prod`)** — Factor III explicitly warns against this: "developers may add their own special environments like `joes-staging`, resulting in a combinatorial explosion of config which makes managing deploys of the app very brittle." Source: https://12factor.net/config.
- **Config files alongside code** (e.g. `config/database.yml`) — improvement over constants, but still leaks into version control. Source: same.
- **Process state held in-process** (Factor VI) — common anti-pattern: caching user sessions in process memory. Use Redis/external. Source: https://12factor.net/processes.
- **In-app log file writers** (Factor XI) — they're invisible across replicas, prevent stdout-based aggregators from working, and require log rotation. Source: https://12factor.net/logs.
- **Slow boot** (Factor IX) — large apps that take 30+ s to start violate disposability; under load they slow down rolling restarts. Source: https://12factor.net/disposability.

## Authoritative URLs to cite in our docs

- https://12factor.net/
- https://12factor.net/codebase
- https://12factor.net/dependencies
- https://12factor.net/config
- https://12factor.net/backing-services
- https://12factor.net/build-release-run
- https://12factor.net/processes
- https://12factor.net/port-binding
- https://12factor.net/concurrency
- https://12factor.net/disposability
- https://12factor.net/dev-prod-parity
- https://12factor.net/logs
- https://12factor.net/admin-processes

## AUDIT CHECKLIST for the Audit Agent

For each factor, check the cluster's deploy and code paths:

1. **I. Codebase:** confirm `alfa-ai`, `rankings-bot`, `atems`, `contracts-bot`, `credit-check-bot`, `market-pie5-bot` each map 1:1 to a Git repo (per `AGENTS.md`). Multiple deploys of the same code (e.g. `hub` brain + `apps` brain mirror) must derive from the same `git pull`. Cross-check `SOURCE_OF_TRUTH_AND_SYNC.md`.
2. **II. Dependencies:** confirm Python services pin `requirements.txt` (or `pyproject.toml` + lockfile), Node services pin `package-lock.json` / `pnpm-lock.yaml`. Containers must `COPY requirements.txt` separately from code for layer caching.
3. **III. Config:** grep the repo for hard-coded secrets (`HF_TOKEN=`, `LITELLM_MASTER_KEY=`, DB passwords) — none should be committed. `deploy/env.example` is committed (template); `deploy/.env` is gitignored. Cross-check `DOCUMENTATION_CANONICAL.md` "Operator-owned" diff process. Also verify no per-deploy "environment" grouping is hard-coded into routing.
4. **IV. Backing services:** confirm `OLLAMA_BASE_URL`, `EMBED_BASE_URL`, `LITELLM_PROXY_URL`, `POSTGRES_URL`, `REDIS_URL`, `PETALS_GATEWAY_*`, `LLAMACPP_RPC_URL` are all read from env. Swapping `hub` → `orchestrator` for the brain (per `ROADMAP.md` "Brain to orchestrator") should require only env changes, not code changes.
5. **V. Build, release, run:** confirm Docker image tags are immutable (pinned by digest preferred; tag with git SHA acceptable). The `deploy/cluster-members/*/deploy.{sh,ps1}` flow should not mutate the running release; must roll a new release.
6. **VI. Processes:** confirm `alfa-ai-api` and bot APIs do not hold session state in-process. Sessions/RAG state should live in Postgres/Redis. Stickiness should NOT be required at the load balancer.
7. **VII. Port binding:** every service binds its own port (`uvicorn --host 0.0.0.0`); nginx is a separate process. Confirms across `deploy/docker-compose.yml`.
8. **VIII. Concurrency:** confirm horizontal scale = more workers/replicas, not a bigger single process. The `--num_workers $(nproc)` LiteLLM pattern (per `litellm.md`) is exactly this.
9. **IX. Disposability:** confirm services handle SIGTERM gracefully — FastAPI's lifespan shutdown, LiteLLM's graceful drain, nginx `nginx -s quit`. Container `stop_grace_period:` should be ≥ longest in-flight request (e.g. 30s for chat completions).
10. **X. Dev/prod parity:** confirm dev work uses the same Postgres/Redis/Ollama versions as prod. Per `AGENTS.md` "Multi-Bot Changes": all four bots use the same `@/contexts/AuthContext` pattern, slate-950 theme, `@/` aliases. Drift = parity violation.
11. **XI. Logs:** confirm services log to stdout/stderr, NOT to in-container log files. `docker compose logs <svc>` should be the canonical access pattern. Check FastAPI `logging.basicConfig`, LiteLLM `json_logs: true`, nginx `access_log /var/log/nginx/...` (Docker maps stdout via the official image's `daemon.json off` symlink).
12. **XII. Admin processes:** confirm DB migrations (`prisma migrate deploy`, `alembic upgrade`), one-time pulls (`scripts/cluster-members/_common/pull-models.sh`) run as one-off jobs against the same release. Cross-reference `litellm.md` audit item on `USE_PRISMA_MIGRATE`.
