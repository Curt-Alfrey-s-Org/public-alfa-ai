#!/usr/bin/env bash
# Insert /api/ proxy into USPBF maintenance www server block if missing.
set -euo pipefail

CONF="${1:-/home/operator/USPBF/nginx-config/uspbf-nginx-maintenance.conf}"

python3 - "$CONF" << 'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

www_marker = "server_name www.uspbf.com uspbf.com;"
if www_marker not in text:
    raise SystemExit("www.uspbf.com server block not found")

parts = text.split(www_marker, 1)
head, tail = parts[0], www_marker + parts[1]
# Only inspect the next server block (until "# ---..." next section or second server {)
block_end = re.search(r"\n}\n\n# -{5,}", tail)
www_block = tail[: block_end.end() - len("\n\n#")] if block_end else tail.split("\n}\n", 1)[0] + "\n}"

if "location /api/" in www_block:
    print("[patch-uspbf-maint-api] www block already has /api/")
    sys.exit(0)

api_block = """
    location /api/ {
        include /etc/nginx/snippets/bot-api-key-headers.conf;
        proxy_pass http://rankings_bot_api;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_method $request_method;
        proxy_set_header Host app.uspbf.com;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Authorization $http_authorization;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 900s;
        proxy_send_timeout 900s;
        add_header Cache-Control "no-store, no-cache, must-revalidate" always;
    }

"""

needle = "    location / {\n        try_files $uri $uri/ /index.html;\n    }"
if needle not in www_block:
    raise SystemExit("Could not find location / in www maintenance block")

new_www = www_block.replace(needle, api_block + needle, 1)
new_tail = new_www + tail[len(www_block):]
path.write_text(head + new_tail, encoding="utf-8")
print("[patch-uspbf-maint-api] added /api/ to www maintenance server block")
PY
