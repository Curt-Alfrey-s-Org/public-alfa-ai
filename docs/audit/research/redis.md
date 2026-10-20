# Redis

> Research-agent output for the ALFa AI architecture audit (2026-05-13).
> Read by `audit-agent` to check `/home/operator/alfa-ai/` against upstream guidance.

## Official documentation

- **Primary docs URL:** https://redis.io/docs/latest/
- **Administration:** https://redis.io/docs/latest/operate/oss_and_stack/management/admin/
- **Security:** https://redis.io/docs/latest/operate/oss_and_stack/management/security/
- **ACL:** https://redis.io/docs/latest/operate/oss_and_stack/management/security/acl/
- **Persistence:** https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/
- **Open-source release notes:** https://github.com/redis/redis/releases
- **Redis Software / Stack release notes:** https://redis.io/docs/latest/operate/oss_and_stack/stack-with-enterprise/release-notes/
- **Source:** https://github.com/redis/redis (Redis OSS / Open Source) — note: license re-relicensed under RSALv2/SSPL in 2024; Valkey fork at https://github.com/valkey-io/valkey.

## Current stable / supported version (as of 2026-05-13)

- **Latest open-source stable:** `7.2.14` (released 2026-05-05, **security release**). Source: https://github.com/redis/redis/releases/tag/7.2.14.
- **Security fixes in 7.2.14 (CRITICAL):**
  - **CVE-2026-23479** — use-after-free in unblock client flow → potential RCE.
  - **CVE-2026-25243** — invalid memory access in `RESTORE` → potential RCE.
  - **CVE-2026-23631** — Lua use-after-free → potential RCE.
  - Also: SUBSCRIBE/PSUBSCRIBE/SSUBSCRIBE OOM crash, CONFIG SET char validation, SCRIPT DEBUG crash.
  Source: https://redis.io/blog/security-advisory-cve202623479-cve202625243-cve-2026-25588-cve202625589-cve-2026-23631/.
- **Newer supported lines for Redis Software (Enterprise):** 7.4.x default in Redis Software 7.8.6-260 (April 2026), with 7.2.4 and 6.2.13 also supported as DB engines. Source: https://redis.io/docs/latest/operate/rs/release-notes/rs-7-8-releases/rs-7-8-6-260/.
- **EOL policy:** Redis OSS does not publish a fixed-window LTS; security backports historically land in the most recent two minor lines (7.2.x and 7.4.x at present). Track via the security blog feed.
- **Licensing note:** Redis OSS 7.4 onward is dual-licensed RSALv2 / SSPLv1. For pure-OSS users, **Valkey** (BSD) is the upstream-compatible fork. Source: https://valkey.io.

## Key official best practices

- **Bind explicitly:** `bind 127.0.0.1` (loopback) is the safest default. **Never expose Redis to the public internet** — single `FLUSHALL` from an attacker = total data loss. Source: https://redis.io/docs/latest/operate/oss_and_stack/management/security/.
- **Protected mode:** since 3.2.0, Redis enters "protected mode" when started with default config (binds all interfaces, no password) — refuses non-loopback queries until you set `requirepass` or `bind`. Don't bypass this without intent. Source: same.
- **Authentication:** prefer **ACL** (Redis 6+, `ACL SETUSER ...`) for named users + fine-grained permissions. `requirepass` is the legacy single-password form. Source: https://redis.io/docs/latest/operate/oss_and_stack/management/security/acl/.
- **TLS:** Redis supports TLS on client, replication, and Cluster bus. Configure via `tls-port`, `tls-cert-file`, `tls-key-file`, `tls-ca-cert-file`. Source: https://redis.io/docs/latest/operate/oss_and_stack/management/security/.
- **Disable dangerous commands** when exposing a managed Redis: `rename-command CONFIG ""` (or to an unguessable name), same for `DEBUG`, `SHUTDOWN`, `FLUSHDB`, `FLUSHALL`. Increasingly: prefer ACL-based command restriction over `rename-command` (the latter is documented as deprecated and "may be removed in future versions"). Source: same security page.
- **Linux kernel tuning:**
  - `vm.overcommit_memory = 1` in `/etc/sysctl.conf` (avoids `fork()` failure under memory pressure).
  - `echo never > /sys/kernel/mm/transparent_hugepage/enabled` (THP causes latency spikes).
  - Enable swap sized to RAM.
  Source: https://redis.io/docs/latest/operate/oss_and_stack/management/admin/ ("Linux", "Memory").
- **`maxmemory`:** always set explicitly; otherwise OOM-kill is possible. Set `maxmemory-policy` (e.g. `allkeys-lru` for cache, `noeviction` for queue/state). Source: same admin page.
- **Persistence:** choose AOF (append-only file, durable) or RDB (snapshots, fast restart) or both. For a session-store + LiteLLM cache use case (state is rebuildable), RDB is fine; for queue/state, AOF with `appendfsync everysec` (default) is the standard. Source: https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/.
- **Replication backlog:** size proportional to memory; allows replicas to catch up without full sync after short disconnects. Source: https://redis.io/docs/latest/operate/oss_and_stack/management/admin/.
- **Replica behavior on master crash:** if master restarts with empty data and replica auto-syncs, the replica is wiped. Either enable persistence on master OR `slave-serve-stale-data no` to require manual recovery. Source: same.
- **Don't run as root:** create a dedicated `redis` user. Source: https://redis.io/docs/latest/operate/oss_and_stack/management/security/ ("Code security").
- **Container image:** the official Docker image is `redis:7-alpine` (or `redis:7.2-alpine`). Pin a specific minor — never `:latest`. Source: https://hub.docker.com/_/redis.

## Canonical configuration examples

**Minimal hardened `redis.conf`** (composed from upstream security + admin pages):

```conf
# Bind only to loopback + the docker network IP this host owns
bind 127.0.0.1 -::1

protected-mode yes
port 6379

# Authentication
requirepass <REPLACE-WITH-LONG-RANDOM-STRING>
# Or use ACL:
# aclfile /etc/redis/users.acl

# Persistence (AOF default)
appendonly yes
appendfsync everysec

# Memory cap + eviction
maxmemory 4gb
maxmemory-policy allkeys-lru

# Disable dangerous commands when reachable from low-trust callers
# Prefer ACL command lists; rename-command is deprecated.
rename-command FLUSHDB ""
rename-command FLUSHALL ""
rename-command CONFIG ""
rename-command DEBUG ""
```

**Linux host prep (`sysctl` + THP):**

```bash
sudo sysctl -w vm.overcommit_memory=1
echo "vm.overcommit_memory = 1" | sudo tee -a /etc/sysctl.conf
echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled
```

Source: https://redis.io/docs/latest/operate/oss_and_stack/management/admin/.

## Common pitfalls / gotchas

- **3 critical RCE CVEs in 2026** (CVE-2026-23479, -25243, -23631). Anything below 7.2.14 is exposed. Source: https://redis.io/blog/security-advisory-cve202623479-cve202625243-cve-2026-25588-cve202625589-cve-2026-23631/.
- **Default `bind` accepting all interfaces** + protected-mode is a fragile combination — once a `requirepass` is set, protected mode is bypassed and the instance is reachable network-wide. Don't rely on protected-mode as a firewall. Source: https://redis.io/docs/latest/operate/oss_and_stack/management/security/.
- **`rename-command` is deprecated** — switch to ACL-based command restriction. Source: same security page.
- **`maxmemory` not set** can OOM-kill the process under load (especially with `BGSAVE` doubling memory at fork time). Source: https://redis.io/docs/latest/operate/oss_and_stack/management/admin/.
- **`vm.overcommit_memory = 0`** (Linux default) causes `fork()` failures during BGSAVE — Redis's FAQ has an entire entry on this. Source: same admin page.
- **Transparent Huge Pages = ON** (default on most Linux distros) causes 100ms+ latency spikes on Redis. Disable explicitly. Source: same.
- **`AUTH` is sent unencrypted** unless TLS is enabled — eavesdroppers on the LAN can capture passwords. Source: https://redis.io/docs/latest/operate/oss_and_stack/management/security/.
- **License change (2024)** — Redis OSS ≥ 7.4 is no longer pure BSD/MIT. For OSS-strict deployments, switch to Valkey. Source: https://valkey.io.

## Authoritative URLs to cite in our docs

- https://redis.io/docs/latest/
- https://redis.io/docs/latest/operate/oss_and_stack/management/admin/
- https://redis.io/docs/latest/operate/oss_and_stack/management/security/
- https://redis.io/docs/latest/operate/oss_and_stack/management/security/acl/
- https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/
- https://github.com/redis/redis/releases
- https://redis.io/blog/security-advisory-cve202623479-cve202625243-cve-2026-25588-cve202625589-cve-2026-23631/
- https://valkey.io
- https://hub.docker.com/_/redis

## AUDIT CHECKLIST for the Audit Agent

1. **Version floor:** confirm Redis on `apps` (per `NODE_INVENTORY.md`) runs ≥ `7.2.14`. Below this, three CVEs (CVE-2026-23479, -25243, -23631) are unpatched. Path: `apps-105/` or per-bot compose files. Flag any `redis:7.2.13` or older.
2. **Bind address:** confirm `bind 127.0.0.1 -::1` (or LAN-only) — never default `*`. Path: mounted `redis.conf` or compose `command:` overrides.
3. **`requirepass` or ACL:** confirm `requirepass <strong>` is set, OR an ACL file (`aclfile`). Empty/default → unauthenticated. Verify the secret is sourced from env, not committed.
4. **`maxmemory` set:** confirm a non-zero `maxmemory` and a `maxmemory-policy`. Without these the OOM-killer can take down `apps` host services. Path: `redis.conf` or compose env.
5. **Persistence model match:** for LiteLLM router state + cache, AOF (`appendonly yes`) or RDB is acceptable; for queue use cases, AOF is the safer choice. Document which mode and why in `apps-105/README.md`.
6. **Linux kernel tuning on `apps`:** confirm `vm.overcommit_memory = 1` in `/etc/sysctl.conf` and THP disabled. These are host-level, not container-level. Path: `apps` ansible playbook or system docs.
7. **Disabled commands:** confirm `FLUSHDB`, `FLUSHALL`, `CONFIG`, `DEBUG`, `SHUTDOWN` are renamed (or ACL-restricted) for any role with low-trust callers. Path: `redis.conf`.
8. **TLS for cross-host:** if any service on `hub` (LiteLLM) connects to Redis on `apps`, confirm TLS is enabled OR the traffic stays on a Docker network that doesn't leave the host. Otherwise `AUTH` is sent in clear over the LAN.
9. **Port binding:** confirm Docker port mapping uses `127.0.0.1:6379:6379` form per workspace `port-assignment-rules.mdc`, OR Redis is only reachable over `tunnel_network` Docker network.
10. **Image tag:** `redis:7.2-alpine` or `redis:7-alpine`, never `:latest`. Path: `apps-105/docker-compose.yml`.
11. **Multiple Redis instances?** the cluster doc references "Redis on `apps`" — verify there is only one canonical instance, not separate per-bot Redis daemons. Multiple instances multiply the attack surface.
12. **Sentinel / Cluster topology:** for the cluster's scale, single-node Redis is acceptable per LiteLLM prod guide. Document explicitly that there is no replica/Sentinel and accept the single-host risk.
