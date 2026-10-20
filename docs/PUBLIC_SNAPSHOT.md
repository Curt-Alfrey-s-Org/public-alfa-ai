# Public snapshot

This tree is a **scrubbed snapshot** of the private `alfa-ai` brain repository. It is **not**
a continuation of private git history and does not record the source commit SHA in this file.

## Configure before you run

Follow **`README.md`** at the repo root: copy example env files, replace `change-me` placeholders,
start Postgres/Redis, then `scripts/start.sh`. Role hostnames live in `config/hosts.example.env`.

Multi-host roles (hub, rag, orchestrator) are optional; single-machine trial uses Docker on one host
only.

## Secrets

Long-lived tokens, database passwords, and SSH private keys stay on the operator machine. See
`deploy/secrets/README.md`.
