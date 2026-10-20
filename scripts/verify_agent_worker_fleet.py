#!/usr/bin/env python3
import os
import sys
sys.path.insert(0, "/app")
from src.api.redis_heartbeat import get_worker_heartbeat

hosts = ["111", "105", "102", "103", "106", "107", "148", "100"]
ok = 0
for host in hosts:
    hb = get_worker_heartbeat(f"alfa-ai-worker-{host}")
    if not hb:
        print(f"{host}: MISSING")
        continue
    extra = hb.get("extra") or {}
    print(f"{host}: {extra.get('status', 'alive')}")
    ok += 1
print(f"alive_count={ok}/{len(hosts)}")
