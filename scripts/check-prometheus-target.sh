#!/usr/bin/env bash
python3 <<'PY'
import json, urllib.request
d = json.load(urllib.request.urlopen("http://127.0.0.1:9092/api/v1/targets"))
for t in d["data"]["activeTargets"]:
    if t["labels"].get("job") == "alfa-ai-incident-metrics":
        print("health:", t["health"])
        print("lastError:", t.get("lastError", "") or "(none)")
        print("lastScrape:", t.get("lastScrape", ""))
        break
else:
    print("job not found")
PY
