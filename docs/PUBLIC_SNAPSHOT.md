# Public snapshot

This tree is a **scrubbed snapshot** of the private `alfa-ai` brain repository. It is **not**
a continuation of private git history and does not record the source commit SHA in this file.

## Configure before you run

1. Copy `config/hosts.example.env` to `config/hosts.env` and set your hostnames or documentation
   addresses (do not commit `hosts.env`).
2. Copy `deploy/env.example` to `deploy/.env` on the hosts where you run Docker stacks, and replace
   every `change-me` placeholder. Never commit live `.env` files.
3. Add your own SSH keys on the orchestrator; this snapshot does not ship house-specific keys.

## Example addresses (RFC 5737)

Role variables live only in `config/hosts.example.env` (`ORCHESTRATOR_HOST`, `APPS_HOST`,
`MARKET_HOST`, `ATEMS_HOST`, `SOLAR_BROKER_HOST`, `HUB_HOST`, `MONITOR_HOST`).

## VPN

Use your own private network path between sites. This snapshot does not include vendor VPN install
steps.

## Secrets

Long-lived tokens, database passwords, and SSH private keys stay on the operator machine. See
`deploy/secrets/README.md`.
