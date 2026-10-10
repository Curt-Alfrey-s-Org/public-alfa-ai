#!/usr/bin/env python3
"""
Queue a single HTTP(S) URI on a remote aria2 JSON-RPC daemon, wait until complete,
then move the finished file to DEST (host path).

Environment:
  ARIA2_RPC_URL       required, e.g. http://hub/jsonrpc
  ARIA2_RPC_KEY    required (no default; must match the aria2 daemon's rpc-secret)
  ARIA2_RPC_DIR      download dir *on the aria2 server* (default /downloads)
  ARIA2_HOST_STAGING  host path bind-mounted to that dir (default /mnt/hub/alfa-ai/models/downloads)
  HF_TOKEN / HUGGING_FACE_HUB_TOKEN   optional Bearer for the URL
  HTTP_FETCH_PROGRESS  set to 0 to disable live status on stderr (default: on when stderr is a TTY)
"""
from __future__ import annotations

import json
import os
import shutil
import sys
import time
import urllib.error
import urllib.request


def _as_int(v) -> int:
    try:
        return int(v)
    except (TypeError, ValueError):
        return 0


def _human_bytes(n: int) -> str:
    if n < 0:
        n = 0
    units = ("B", "KiB", "MiB", "GiB", "TiB")
    v = float(n)
    for u in units:
        if v < 1024.0 or u == "TiB":
            if u == "B":
                return f"{int(v)} {u}"
            return f"{v:.2f} {u}"
        v /= 1024.0
    return f"{n} B"


def post(rpc_url: str, payload: dict) -> dict:
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        rpc_url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read().decode())


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: aria2_jsonrpc_fetch.py <url> <dest_host_path>", file=sys.stderr)
        return 2

    url, dest = sys.argv[1], sys.argv[2]
    rpc_url = os.environ.get("ARIA2_RPC_URL", "").strip()
    if not rpc_url:
        print("ARIA2_RPC_URL is not set", file=sys.stderr)
        return 1

    secret = os.environ.get("ARIA2_RPC_KEY", "").strip()
    if not secret:
        print("ARIA2_RPC_KEY is not set (see deploy/aria2/README.md)", file=sys.stderr)
        return 1
    rpc_dir = os.environ.get("ARIA2_RPC_DIR", "/downloads")
    staging = os.environ.get(
        "ARIA2_HOST_STAGING", "/mnt/hub/alfa-ai/models/downloads"
    ).rstrip("/")
    out_name = os.path.basename(dest)

    headers = {}
    hf_tok = os.environ.get("HF_TOKEN") or os.environ.get("HUGGING_FACE_HUB_TOKEN")
    if hf_tok:
        headers["Authorization"] = f"Bearer {hf_tok}"

    # aria2.addUri: params [token, [uris], {dir, out, header}]
    opts: dict = {"dir": rpc_dir, "out": out_name}
    if headers:
        # aria2 expects header list as strings "Key: Value"
        opts["header"] = [f"{k}: {v}" for k, v in headers.items()]

    params = [f"token:{secret}", [url], opts]
    body = {"jsonrpc": "2.0", "id": "add", "method": "aria2.addUri", "params": params}
    try:
        res = post(rpc_url, body)
    except urllib.error.URLError as e:
        print(f"RPC error: {e}", file=sys.stderr)
        return 1
    if "error" in res:
        print(f"aria2.addUri error: {res['error']}", file=sys.stderr)
        return 1
    gid = res.get("result")
    if not gid:
        print(f"unexpected response: {res}", file=sys.stderr)
        return 1

    verbose = sys.stderr.isatty() and os.environ.get("HTTP_FETCH_PROGRESS", "1") != "0"
    print(f"aria2 gid={gid} (polling …)", flush=True)
    for _ in range(86400):  # up to 24h at 1s interval
        time.sleep(1)
        st = post(
            rpc_url,
            {
                "jsonrpc": "2.0",
                "id": "st",
                "method": "aria2.tellStatus",
                "params": [f"token:{secret}", gid],
            },
        )
        if "error" in st:
            if verbose:
                print(file=sys.stderr)
            print(f"tellStatus error: {st['error']}", file=sys.stderr)
            return 1
        result = st.get("result", {})
        status = result.get("status")
        if verbose and status in ("active", "waiting", "paused"):
            comp = _as_int(result.get("completedLength"))
            tot = _as_int(result.get("totalLength"))
            spd = _as_int(result.get("downloadSpeed"))
            tot_s = _human_bytes(tot) if tot else "?"
            line = (
                f"\r  aria2 RPC: {_human_bytes(comp)} / {tot_s}  "
                f"{_human_bytes(spd)}/s  [{status}]"
            )
            print(line, end="", file=sys.stderr, flush=True)
        if status == "complete":
            if verbose:
                print(file=sys.stderr)
            break
        if status == "error":
            if verbose:
                print(file=sys.stderr)
            print(f"download error: {st.get('result')}", file=sys.stderr)
            return 1
    else:
        if verbose:
            print(file=sys.stderr)
        print("timeout waiting for aria2", file=sys.stderr)
        return 1

    staged = os.path.join(staging, out_name)
    if not os.path.isfile(staged):
        print(f"missing file after complete: {staged}", file=sys.stderr)
        return 1

    dest = os.path.abspath(dest)
    staged = os.path.abspath(staged)
    if os.path.normpath(staged) == os.path.normpath(dest):
        print(f"already at destination: {dest}")
        return 0

    os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
    shutil.move(staged, dest)
    print(f"moved -> {dest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
