#!/usr/bin/env python3
"""Detect silent model-config and deploy drift before rollout.

Compares deploy/model_config_manifest.json against committed templates, Python
constants, LiteLLM routing, and (optionally) live deploy/.env or running API.

Usage:
  python scripts/audit_model_config.py
  python scripts/audit_model_config.py --env deploy/.env
  python scripts/audit_model_config.py --live http://127.0.0.1:8412
  python scripts/audit_model_config.py --strict

Exit 0 = no errors (warnings may still print). Exit 1 = at least one error.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Any
from urllib.error import URLError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

MANIFEST_PATH = ROOT / "deploy" / "model_config_manifest.json"

COMPOSE_DEFAULT_MODEL_RE = re.compile(
    r"DEFAULT_MODEL=\$\{DEFAULT_MODEL:-([^}]+)\}"
)
COMPOSE_BUILD_HASH_ARG_RE = re.compile(
    r"BUILD_HASH:\s*\$\{BUILD_HASH:-([^}]+)\}"
)
COMPOSE_IMAGE_TAG_RE = re.compile(
    r"image:\s*alfa-ai-app:\$\{BUILD_HASH:-([^}]+)\}"
)
LITELLM_MODEL_NAME_RE = re.compile(r'model_name:\s*"([^"]+)"')
ENV_KV_RE = re.compile(r"^([A-Z_][A-Z0-9_]*)=(.*)$")


class Finding:
    __slots__ = ("level", "code", "message")

    def __init__(self, level: str, code: str, message: str) -> None:
        self.level = level
        self.code = code
        self.message = message


def load_manifest() -> dict[str, Any]:
    data = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    if not data.get("production_default"):
        raise SystemExit(f"Invalid manifest: {MANIFEST_PATH}")
    return data


def parse_env_file(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not path.is_file():
        return out
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = ENV_KV_RE.match(line)
        if not m:
            continue
        key, val = m.group(1), m.group(2).strip()
        if val.startswith('"') and val.endswith('"'):
            val = val[1:-1]
        elif val.startswith("'") and val.endswith("'"):
            val = val[1:-1]
        out[key] = val
    return out


def litellm_model_names(path: Path) -> set[str]:
    text = path.read_text(encoding="utf-8", errors="replace")
    return set(LITELLM_MODEL_NAME_RE.findall(text))


def split_chat_models(raw: str) -> list[str]:
    aliases: list[str] = []
    for part in raw.split(","):
        part = part.strip()
        if not part:
            continue
        alias = part.split("|", 1)[0].strip()
        if alias:
            aliases.append(alias)
    return aliases


def audit_manifest_vs_python(manifest: dict[str, Any]) -> list[Finding]:
    from src.api import llm_config

    findings: list[Finding] = []
    retired = {a.lower() for a in manifest["retired_chat_aliases"]}
    py_retired = {a.lower() for a in llm_config.RETIRED_CHAT_ALIASES}
    if retired != py_retired:
        findings.append(
            Finding(
                "error",
                "RETIRED_MISMATCH",
                "llm_config.RETIRED_CHAT_ALIASES != manifest retired_chat_aliases",
            )
        )

    prod = manifest["production_default"]
    # Compare the committed constant, not runtime DEFAULT_MODEL (local .env must not
    # fail template drift checks; live env is audited separately).
    if llm_config.PRODUCTION_DEFAULT_ALIAS != prod:
        findings.append(
            Finding(
                "error",
                "DEFAULT_PY",
                f"llm_config production default != manifest ({prod!r})",
            )
        )

    picker = manifest["picker_aliases"]
    if list(llm_config._DEFAULT_PICKER_ALIASES) != picker:
        findings.append(
            Finding(
                "error",
                "PICKER_PY",
                "llm_config._DEFAULT_PICKER_ALIASES != manifest picker_aliases",
            )
        )
    return findings


def audit_committed_templates(manifest: dict[str, Any]) -> list[Finding]:
    findings: list[Finding] = []
    prod = manifest["production_default"]
    picker = set(manifest["picker_aliases"])
    retired = {a.lower() for a in manifest["retired_chat_aliases"]}

    env_ex = ROOT / "deploy" / "env.example"
    env_vals = parse_env_file(env_ex)
    if env_vals.get("DEFAULT_MODEL") != prod:
        findings.append(
            Finding(
                "error",
                "ENV_EXAMPLE_DEFAULT",
                f"deploy/env.example DEFAULT_MODEL={env_vals.get('DEFAULT_MODEL')!r} expected {prod!r}",
            )
        )
    for alias in split_chat_models(env_vals.get("CHAT_MODELS", "")):
        if alias.lower() in retired:
            findings.append(
                Finding(
                    "error",
                    "ENV_EXAMPLE_RETIRED",
                    f"deploy/env.example CHAT_MODELS contains retired alias {alias!r}",
                )
            )

    root_env = parse_env_file(ROOT / "env.example")
    if root_env.get("DEFAULT_MODEL") and root_env.get("DEFAULT_MODEL") != prod:
        findings.append(
            Finding(
                "error",
                "ROOT_ENV_DEFAULT",
                f"env.example DEFAULT_MODEL={root_env.get('DEFAULT_MODEL')!r} expected {prod!r}",
            )
        )

    compose = (ROOT / "deploy" / "docker-compose.yml").read_text(encoding="utf-8")
    compose_defaults = COMPOSE_DEFAULT_MODEL_RE.findall(compose)
    for val in compose_defaults:
        if val != prod:
            findings.append(
                Finding(
                    "error",
                    "COMPOSE_DEFAULT_MODEL",
                    f"docker-compose DEFAULT_MODEL fallback {val!r} != {prod!r}",
                )
            )

    build_args = COMPOSE_BUILD_HASH_ARG_RE.findall(compose)
    image_tags = COMPOSE_IMAGE_TAG_RE.findall(compose)
    tag_default = manifest.get("compose_image_tag_default", "local")
    for val in build_args:
        if val != tag_default:
            findings.append(
                Finding(
                    "error",
                    "BUILD_HASH_ARG",
                    f"compose BUILD_HASH build-arg default {val!r} != image tag default {tag_default!r}",
                )
            )
    for val in image_tags:
        if val != tag_default:
            findings.append(
                Finding(
                    "error",
                    "BUILD_HASH_TAG",
                    f"compose image tag default {val!r} != {tag_default!r}",
                )
            )
    if build_args and image_tags and set(build_args) != set(image_tags):
        findings.append(
            Finding(
                "error",
                "BUILD_HASH_SPLIT",
                f"compose BUILD_HASH build-arg defaults {build_args} != image tag defaults {image_tags}",
            )
        )

    litellm_path = ROOT / manifest["files"]["litellm_config"]
    routed = litellm_model_names(litellm_path)
    missing = sorted(picker - routed)
    if missing:
        findings.append(
            Finding(
                "error",
                "LITELLM_PICKER",
                f"picker aliases missing from litellm_config.yaml: {missing}",
            )
        )

    client_py = (ROOT / "src" / "llm" / "client.py").read_text(encoding="utf-8")
    if 'get("DEFAULT_MODEL", "qwen3.6:35b-a3b")' in client_py and "sanitize_chat_model_alias" not in client_py:
        findings.append(
            Finding(
                "error",
                "CLIENT_UNSANITIZED",
                "src/llm/client.py reads DEFAULT_MODEL without sanitize_chat_model_alias",
            )
        )

    app_py = (ROOT / "src" / "api" / "app.py").read_text(encoding="utf-8")
    if "operator_api_config" in app_py and "sanitize_chat_model_alias" not in app_py:
        findings.append(
            Finding(
                "error",
                "OPERATOR_CONFIG_UNSANITIZED",
                "operator_api_config does not sanitize DEFAULT_MODEL",
            )
        )

    preflight = (ROOT / "scripts" / "alfa_ai_rollout_preflight.sh").read_text(encoding="utf-8")
    if 'ALFA_AI_API_HOST_PORT:-8012' in preflight:
        findings.append(
            Finding(
                "error",
                "PREFLIGHT_PORT",
                "alfa_ai_rollout_preflight.sh default API port 8012 != canonical 8412",
            )
        )

    return findings


def audit_deploy_env(manifest: dict[str, Any], env_path: Path) -> list[Finding]:
    findings: list[Finding] = []
    if not env_path.is_file():
        findings.append(
            Finding(
                "warn",
                "ENV_MISSING",
                f"deploy env not found: {env_path} (skipped live env checks)",
            )
        )
        return findings

    vals = parse_env_file(env_path)
    prod = manifest["production_default"]
    retired = {a.lower() for a in manifest["retired_chat_aliases"]}

    dm = vals.get("DEFAULT_MODEL", "")
    if dm.lower() in retired:
        findings.append(
            Finding(
                "error",
                "LIVE_ENV_RETIRED_DEFAULT",
                f"{env_path}: DEFAULT_MODEL={dm!r} is retired (API sanitizes at runtime but fix .env)",
            )
        )
    elif dm and dm != prod:
        findings.append(
            Finding(
                "warn",
                "LIVE_ENV_DEFAULT_DRIFT",
                f"{env_path}: DEFAULT_MODEL={dm!r} != manifest {prod!r}",
            )
        )

    for alias in split_chat_models(vals.get("CHAT_MODELS", "")):
        if alias.lower() in retired:
            findings.append(
                Finding(
                    "error",
                    "LIVE_ENV_RETIRED_PICKER",
                    f"{env_path}: CHAT_MODELS contains retired alias {alias!r}",
                )
            )

    operator_model = str(manifest.get("operator_model", "qwen3:8b"))
    op = vals.get("OPERATOR_CHAT_MODEL", "")
    if op and op.lower() in retired and op.lower() != operator_model.lower():
        findings.append(
            Finding(
                "error",
                "LIVE_ENV_RETIRED_OPERATOR",
                f"{env_path}: OPERATOR_CHAT_MODEL={op!r} is retired",
            )
        )

    return findings


def audit_live_api(base_url: str, manifest: dict[str, Any]) -> list[Finding]:
    findings: list[Finding] = []
    url = base_url.rstrip("/") + "/api/admin/health"
    req = Request(url, headers={"Accept": "application/json"})
    try:
        with urlopen(req, timeout=8) as resp:
            body = json.loads(resp.read().decode("utf-8"))
    except URLError as exc:
        findings.append(
            Finding("warn", "LIVE_API_UNREACHABLE", f"Could not GET {url}: {exc}")
        )
        return findings

    build_hash = str(body.get("build_hash", "")).strip()
    bad = {"", "unknown", "local"}
    if build_hash.lower() in bad:
        findings.append(
            Finding(
                "error",
                "LIVE_BUILD_HASH",
                f"Running API build_hash={build_hash!r} -- rebuild with "
                "BUILD_HASH=$(scripts/docker_build_hash.sh) or scripts/brain_redeploy_api.sh",
            )
        )
    return findings


def main() -> int:
    parser = argparse.ArgumentParser(description="Audit model config drift")
    parser.add_argument(
        "--env",
        default=str(ROOT / "deploy" / ".env"),
        help="Path to deploy/.env (default: deploy/.env)",
    )
    parser.add_argument(
        "--live",
        metavar="URL",
        default="",
        help="Optional API base URL for live build_hash check (e.g. http://127.0.0.1:8412)",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Treat warnings as errors",
    )
    parser.add_argument(
        "--skip-env",
        action="store_true",
        help="Skip deploy/.env checks (CI without secrets)",
    )
    args = parser.parse_args()

    manifest = load_manifest()
    findings: list[Finding] = []
    findings.extend(audit_manifest_vs_python(manifest))
    findings.extend(audit_committed_templates(manifest))
    if not args.skip_env:
        findings.extend(audit_deploy_env(manifest, Path(args.env)))
    if args.live:
        findings.extend(audit_live_api(args.live, manifest))

    errors = [f for f in findings if f.level == "error"]
    warns = [f for f in findings if f.level == "warn"]

    for f in findings:
        prefix = "ERROR" if f.level == "error" else "WARN"
        print(f"[{prefix}] {f.code}: {f.message}")

    if not findings:
        print("OK: no drift detected")
        return 0

    print(f"\nSummary: {len(errors)} error(s), {len(warns)} warning(s)")
    if errors or (args.strict and warns):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
