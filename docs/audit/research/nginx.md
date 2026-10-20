# nginx

> Research-agent output for the ALFa AI architecture audit (2026-05-13).
> Read by `audit-agent` to check `/home/operator/alfa-ai/` against upstream guidance.

## Official documentation

- **Primary docs URL:** https://nginx.org/en/docs/
- **Beginner's guide:** https://nginx.org/en/docs/beginners_guide.html
- **`ngx_http_proxy_module`:** https://nginx.org/en/docs/http/ngx_http_proxy_module.html
- **`ngx_core_module`:** https://nginx.org/en/docs/ngx_core_module.html
- **Changelog (definitive):** https://nginx.org/en/CHANGES
- **Source repo:** https://github.com/nginx/nginx (mirror) — canonical source is https://hg.nginx.org
- **Security advisories:** https://nginx.org/en/security_advisories.html

## Current stable / supported version (as of 2026-05-13)

- **Latest mainline:** `nginx 1.29.8` (released 2026-04-07). New: `max_headers` directive, OpenSSL 4.0 compat, wildcards in `geo` includes. Source: https://nginx.org/en/CHANGES.
- **Most recent security release:** `nginx 1.29.7` (2026-03-24) — fixes **5 CVEs**: CVE-2026-27654 (buffer overflow in COPY/MOVE under `alias`), CVE-2026-27784 / CVE-2026-32647 (`ngx_http_mp4_module` worker crashes), CVE-2026-27651 (CRAM-MD5/APOP segfault), CVE-2026-28755 (stream OCSP-rejection bypass), CVE-2026-28753 (PTR DNS injection in `auth_http`/XCLIENT). Source: https://nginx.org/en/CHANGES.
- **Major default changes in 1.29.7:** `keepalive` enabled by default in upstreams; `proxy_http_version` defaults to `1.1`; `Connection` proxy header is no longer sent by default. Source: https://nginx.org/en/CHANGES.
- **Stable branches:** nginx ships two parallel branches at any time — *mainline* (odd minor, e.g. 1.29.x) gets all features and fixes; *stable* (even minor) gets only bugfixes. Production sites typically run mainline because security fixes ship there first. Source: https://nginx.org/en/download.html and https://www.nginx.com/blog/nginx-1-21-3-mainline-vs-stable/ (general nginx versioning policy).
- **EOL:** older mainline branches are unsupported once a new one starts. There is no formal LTS — all supported security fixes go into the current mainline (1.29.x at the time of writing). Source: https://nginx.org/en/CHANGES (only one mainline gets fixes).

## Key official best practices

- **Worker process count:** set `worker_processes auto;` so nginx auto-tunes to CPU count. Source: https://nginx.org/en/docs/ngx_core_module.html#worker_processes.
- **Reload (zero-downtime):** `nginx -s reload` causes the master to fork new workers, gracefully drain old workers, and roll back if config syntax is invalid. Use `nginx -t` to validate before reload. Source: https://nginx.org/en/docs/beginners_guide.html ("Starting, Stopping, and Reloading Configuration").
- **`server_name` discrimination:** every public-facing virtual host should have an explicit `server_name`; the default unnamed `server` block catches stray traffic. Source: https://nginx.org/en/docs/http/server_names.html.
- **`location` matching order:** prefix locations are checked first (longest wins), then regex. Pin a regex with `~` (case-sensitive) or `~*` (insensitive). Use `^~` to override regex matching for a prefix. Source: https://nginx.org/en/docs/beginners_guide.html.
- **Proxy headers (canonical set when fronting an app):**
  - `proxy_set_header Host $host;`
  - `proxy_set_header X-Real-IP $remote_addr;`
  - `proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;`
  - `proxy_set_header X-Forwarded-Proto $scheme;`
  - `proxy_http_version 1.1;` (now default in 1.29.7+)
  Source: https://nginx.org/en/docs/http/ngx_http_proxy_module.html.
- **WebSocket upgrade headers:** for websockets/SSE through `proxy_pass`, add:
  - `proxy_set_header Upgrade $http_upgrade;`
  - `proxy_set_header Connection "upgrade";`
  - `proxy_read_timeout 3600s;` (or per-app)
  Source: https://nginx.org/en/docs/http/websocket.html.
- **Buffering & timeouts:** for streaming inference responses (LLM token streams), disable buffering on that location: `proxy_buffering off; proxy_cache off; chunked_transfer_encoding on;`. Source: https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_buffering.
- **Upstream blocks:** declare upstream pools with `upstream <name> { server ip:port; ... }`. Use `keepalive 32;` (now default in 1.29.7+) to keep connections warm to backends. Source: https://nginx.org/en/docs/http/ngx_http_upstream_module.html.
- **Logging:** `access_log` and `error_log` paths default to `/var/log/nginx/{access,error}.log`. Use `log_format` to add custom fields (latency, upstream addr) for observability. Source: https://nginx.org/en/docs/http/ngx_http_log_module.html.
- **Container image:** the official Docker image is `nginx:<version>-alpine` (smaller) or `nginx:<version>` (Debian). Source: https://hub.docker.com/_/nginx (links from https://nginx.org/en/docs/).

## Canonical configuration examples

**Reverse proxy + SPA fallback** (composed from beginner's guide and proxy module docs):

```nginx
upstream alfa_ai_api {
    server alfa-ai-api:8000;     # docker DNS
    keepalive 32;
}

server {
    listen 80;
    server_name chat.example.com;
    root /usr/share/nginx/html;

    # SPA: serve index.html for unknown paths
    location / {
        try_files $uri $uri/ /index.html;
    }

    # Long-cache hashed assets
    location ~* \.(js|css|woff2|svg|png|jpg|webp)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    # Force-revalidate the entry point so deploys are picked up
    location = /index.html {
        add_header Cache-Control "no-cache";
    }

    # API reverse proxy
    location /api/ {
        proxy_pass         http://alfa_ai_api/;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
    }

    # SSE / WebSocket / streaming LLM responses
    location /api/stream {
        proxy_pass         http://alfa_ai_api/stream;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade           $http_upgrade;
        proxy_set_header   Connection        "upgrade";
        proxy_buffering    off;
        proxy_cache        off;
        proxy_read_timeout 3600s;
    }
}
```

Sources:
- https://nginx.org/en/docs/beginners_guide.html
- https://nginx.org/en/docs/http/ngx_http_proxy_module.html
- https://nginx.org/en/docs/http/websocket.html

## Common pitfalls / gotchas

- **CVE-2026-27654 (path traversal via COPY/MOVE under `alias`)** — fixed in 1.29.7. Anything < 1.29.7 is vulnerable when WebDAV is on. Source: https://nginx.org/en/CHANGES.
- **`proxy_buffering on` (default)** breaks LLM token streaming and SSE — must `proxy_buffering off` on streaming locations. Source: https://nginx.org/en/docs/http/ngx_http_proxy_module.html.
- **Trailing slash in `proxy_pass`** changes URI rewriting behavior — `proxy_pass http://up/;` strips the matched location prefix; `proxy_pass http://up;` (no slash) preserves it. Easy to misconfigure for `/api/` rewrites. Source: https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_pass.
- **Reload picks up syntax errors only at reload time** — validate with `nginx -t` first. Source: https://nginx.org/en/docs/beginners_guide.html.
- **Default `keepalive` was off pre-1.29.7;** if you upgrade past 1.29.7, double-check upstream connection budget (now reused). Source: https://nginx.org/en/CHANGES (1.29.7 changes).
- **Default `proxy_http_version` was `1.0` pre-1.29.7;** chunked transfer-encoded streaming responses behaved differently. New default is `1.1`. Source: same.
- **`$host` vs `$http_host` vs `$server_name`:** for `Host` header forwarding, prefer `$host` (handles missing `Host` header gracefully). Source: https://nginx.org/en/docs/http/ngx_http_core_module.html#var_host.

## Authoritative URLs to cite in our docs

- https://nginx.org/en/docs/
- https://nginx.org/en/docs/beginners_guide.html
- https://nginx.org/en/docs/http/ngx_http_proxy_module.html
- https://nginx.org/en/docs/http/websocket.html
- https://nginx.org/en/docs/http/ngx_http_upstream_module.html
- https://nginx.org/en/docs/http/ngx_http_core_module.html
- https://nginx.org/en/docs/ngx_core_module.html
- https://nginx.org/en/CHANGES
- https://nginx.org/en/security_advisories.html

## AUDIT CHECKLIST for the Audit Agent

1. **Version floor:** confirm every nginx container in the cluster runs `nginx ≥ 1.29.7` (security floor). Path: `deploy/docker-compose.yml` (`alfa-ai-nginx` image tag), every bot's nginx Dockerfile/compose. Anything older has 5 unpatched CVEs.
2. **`proxy_buffering off` on streaming routes:** verify the location handling streamed LLM responses (chat completions, SSE) sets `proxy_buffering off; proxy_cache off; proxy_read_timeout` ≥ 600s. Path: `deploy/nginx.conf`.
3. **WebSocket headers:** confirm any WS endpoints (chat live, monitoring) include `proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection "upgrade";`. Path: `deploy/nginx.conf`.
4. **Forwarded headers complete:** for routes that hit `alfa-ai-api`, confirm `Host`, `X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Proto` are all set. FastAPI behind nginx behind Cloudflare needs all of them so `--proxy-headers` works.
5. **`server_name` whitelisting:** confirm explicit `server_name` per virtual host, with a default `server { return 444; }` block to drop unmatched traffic. Path: `deploy/nginx.conf`.
6. **`try_files` SPA fallback:** confirm the SPA static root has `try_files $uri $uri/ /index.html` so deep-link refreshes don't 404.
7. **Cache-Control on `index.html`:** confirm `index.html` is served with `Cache-Control: no-cache` so Vite preload errors don't pile up after each deploy. (See companion `react-vite.md` audit item.)
8. **`worker_processes auto;`:** confirm in `nginx.conf` main block.
9. **`upstream` keepalive:** confirm long-lived backends (e.g. `alfa-ai-api`, `alfa-ai-litellm`) use an `upstream { ... keepalive N; }` block, and the `proxy_pass` location uses `proxy_http_version 1.1; proxy_set_header Connection "";` (empty Connection on 1.1).
10. **Internal Docker DNS:** per the workspace's `.cursorrules`, `proxy_pass` must be `http://alfa-ai-api:8000/`, NOT `http://127.0.0.1:8420/`. Verify across `deploy/nginx.conf` and any per-bot nginx configs.
11. **Network membership:** all nginx containers must join `tunnel_network` per workspace rule (`.cursorrules` rule 1). Verify `networks:` section.
12. **Logging:** confirm `access_log` includes upstream timing — at minimum `$request_time $upstream_response_time` — for latency observability across the brain mesh.
13. **TLS termination:** confirm whether nginx terminates TLS itself (and rotates certs) or whether Cloudflare Tunnel terminates upstream of nginx (in which case nginx listens on plain HTTP on the tunnel network). Either path must be documented in `deploy/cluster-members/<host>/`.
