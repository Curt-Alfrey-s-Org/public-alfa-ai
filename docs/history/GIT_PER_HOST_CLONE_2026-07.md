# Git policy change — per-host clone (July 2026)

**Date:** 2026-07-01  
**Supersedes:** `.cursor/rules/git-author-105-only.mdc` (removed)

## What changed

Dedicated VMs (100, 102, 103, 106, 107) each own their repo checkouts. The cluster no longer requires all commits to originate on `apps`.

**New rule:** [git-per-host-clone.mdc](../../.cursor/rules/git-per-host-clone.mdc)

- Edit, commit, and push from the host that owns the clone.
- GitHub is the sync bus; other hosts `git pull --ff-only` before deploy.
- `apps` remains valid for repos still colocated there; `orchestrator` and `pool-opt-in` may push `alfa-ai` when that is where work happened.

## Why

VM split moves repos off the monolithic `apps` apps host. Each VM operator (or agent session on that host) needs local git without copying patches back to `apps`.