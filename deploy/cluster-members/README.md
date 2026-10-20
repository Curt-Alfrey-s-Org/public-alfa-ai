# Cluster member deploy folders

Each subdirectory holds example compose and scripts for one role in your deployment. Before you run
anything:

1. Copy `config/hosts.example.env` to `config/hosts.env` at the repo root and set your hosts.
2. Generate or install **your own SSH keys** on the orchestrator; this snapshot does not include
   house-specific key bootstrap scripts.
3. Copy the relevant `*.env.example` files to local `.env` on each host (never commit `.env`).

See `docs/PUBLIC_SNAPSHOT.md` for the public snapshot policy.
