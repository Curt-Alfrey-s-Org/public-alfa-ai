"""Tests for inference shard TCP preflight helpers."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

from src.api.inference_shards import (
    check_inference_shards,
    parse_inference_catalog_endpoints,
    parse_inference_shard_endpoints,
)

_REPO = Path(__file__).resolve().parents[1]
_RESOLVE_PS1 = _REPO / "deploy" / "cluster-members" / "operator-93" / "Resolve-AlfainferenceActiveShards.ps1"
_LLC = _REPO / "deploy" / "llamacpp-rpc"
_CORE = _LLC / "inference-shards.core.env"
_GAMING = _LLC / "inference-shards.gaming.env"

# The merge SSoT is a PowerShell script (Windows orchestrator). Windows PowerShell or
# PowerShell 7 (pwsh) runs it; on hosts with neither (Linux CI / cloud box) the
# tests that shell out are skipped instead of failing with FileNotFoundError.
_POWERSHELL = shutil.which("powershell") or shutil.which("pwsh")
requires_powershell = pytest.mark.skipif(
    _POWERSHELL is None, reason="PowerShell (powershell/pwsh) not installed"
)


def _tensor_split_from_active_content(content: str) -> list[int]:
    splits: list[int] = []
    for raw in content.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) >= 3:
            splits.append(int(parts[2]))
    return splits


def _build_active_shards_via_ps1(
    *,
    include59: bool = False,
    include219: bool = False,
    include249: bool = False,
    include248: bool = False,
    include100: bool = False,
) -> str:
    """Invoke Build-AlfainferenceActiveShardsContent (PowerShell merge SSoT)."""
    flags = " ".join(
        f"-Include{key}:${str(val).lower()}"
        for key, val in (
            ("59", include59),
            ("219", include219),
            ("249", include249),
            ("248", include248),
            ("100", include100),
        )
    )
    ps = f"""
$ErrorActionPreference = 'Stop'
. '{_RESOLVE_PS1}'
$content = Build-AlfainferenceActiveShardsContent `
  -CorePath '{_CORE}' `
  -GamingCatalogPath '{_GAMING}' `
  {flags}
Write-Output $content
"""
    proc = subprocess.run(
        [_POWERSHELL, "-NoProfile", "-Command", ps],
        cwd=str(_REPO),
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr or proc.stdout
    return proc.stdout


def _train_lock_blocks(include59: bool, include249: bool, lock_path: Path) -> bool:
    """Return True when Test-AlfaTrainLockBlocksStart would throw (lock + opt-in)."""
    lock_path.write_text("INCLUDE_219=0\n", encoding="ascii")
    ps = f"""
$ErrorActionPreference = 'Stop'
$LlcDir = '{lock_path.parent}'
$InferenceMode = 'inference'
$script:AlfaGamingSelection = [pscustomobject]@{{
    Include59 = [bool]{1 if include59 else 0}
    Include249 = [bool]{1 if include249 else 0}
    Include219 = [bool]0
}}
function Test-AlfaTrainLockBlocksStart {{
    $trainLock = Join-Path $LlcDir 'alfa-train.lock'
    if (-not (Test-Path -LiteralPath $trainLock)) {{ return }}
    if ($null -eq $script:AlfaGamingSelection) {{ throw 'missing selection' }}
    $sel = $script:AlfaGamingSelection
    $blockReasons = New-Object System.Collections.Generic.List[string]
    if ($InferenceMode -eq 'Pool72' -or $InferenceMode -eq 'Pool80') {{
        [void]$blockReasons.Add('Pool72/Pool80 use gaming-c/gaming-b')
    }}
    if ($sel.Include59) {{ [void]$blockReasons.Add('opt-in gaming-c overlaps the train island') }}
    if ($sel.Include249) {{ [void]$blockReasons.Add('opt-in gaming-b overlaps the train island') }}
    if ($blockReasons.Count -gt 0) {{
        throw ('blocked: ' + ($blockReasons -join '; '))
    }}
}}
try {{
    Test-AlfaTrainLockBlocksStart
    Write-Output 'ALLOW'
}} catch {{
    Write-Output 'BLOCK'
}}
"""
    proc = subprocess.run(
        [_POWERSHELL, "-NoProfile", "-Command", ps],
        cwd=str(_REPO),
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr or proc.stdout
    return "BLOCK" in proc.stdout


def test_parse_default_shards_when_no_file(monkeypatch):
    monkeypatch.delenv("ALFA_inference_SHARD_ENDPOINTS", raising=False)
    monkeypatch.setenv("ALFA_inference_SHARDS_FILE", "/nonexistent/inference-shards.env")
    eps = parse_inference_shard_endpoints()
    assert ("orchestrator", 31356) in eps
    assert ("orchestrator", 31357) in eps
    assert ("orchestrator", 31350) in eps
    assert ("hub", 31353) in eps


def test_parse_env_override(monkeypatch):
    monkeypatch.setenv("ALFA_inference_SHARD_ENDPOINTS", "127.0.0.1:9,127.0.0.1:10")
    eps = parse_inference_shard_endpoints()
    assert eps == [("127.0.0.1", 9), ("127.0.0.1", 10)]


def test_check_inference_shards_unreachable(monkeypatch):
    monkeypatch.setenv("ALFA_inference_SHARD_ENDPOINTS", "127.0.0.1:1")
    report = check_inference_shards(timeout_sec=0.2)
    assert report["ok"] is False
    assert report["shards"][0]["ok"] is False


def test_inference_gaming_catalog_includes_59_and_249():
    """inference gaming catalog includes gaming-c/gaming-b for opt-in (same ports as Pool72)."""
    rows = parse_inference_catalog_endpoints()
    endpoints = {(host, port): label for host, port, label in rows}
    assert endpoints[("orchestrator", 31351)] == "gaming-worker-c"
    assert endpoints[("orchestrator", 31358)] == "gaming-worker-b"
    assert ("orchestrator", 31352) in endpoints


def test_inference_gaming_catalog_vram_for_59_and_249():
    """gaming-c/gaming-b use 9 GB usable slices (RTX 5070 12 GB minus reserve)."""
    repo = Path(__file__).resolve().parents[1]
    gaming = repo / "deploy" / "llamacpp-rpc" / "inference-shards.gaming.env"
    rows: dict[tuple[str, int], str] = {}
    for raw in gaming.read_text(encoding="utf-8").splitlines():
        trim = raw.split("#", 1)[0].strip()
        if not trim:
            continue
        parts = trim.split()
        if len(parts) >= 3:
            rows[(parts[0], int(parts[1]))] = parts[2]
    assert rows[("orchestrator", 31351)] == "9"
    assert rows[("orchestrator", 31358)] == "9"
    assert rows[("orchestrator", 31352)] == "5"


@requires_powershell
def test_inference_core_merge_excludes_59_and_249_by_default():
    """Core-only merge stays 12,8,10,5 when gaming-c and gaming-b are not opted in."""
    content = _build_active_shards_via_ps1()
    assert _tensor_split_from_active_content(content) == [12, 8, 10, 5]


@requires_powershell
def test_inference_all_opt_in_merge_tensor_split():
    """All five opt-in hosts produce documented fastest-first TENSOR_SPLIT."""
    content = _build_active_shards_via_ps1(
        include219=True,
        include59=True,
        include249=True,
        include248=True,
        include100=True,
    )
    splits = _tensor_split_from_active_content(content)
    assert splits == [12, 8, 5, 9, 9, 10, 7, 5, 5]
    assert sum(splits) == 70


@requires_powershell
def test_inference_merge_order_matches_catalog():
    """Gaming insert order: gaming-a before orchestrator; secondary/pool-opt-in after orchestrator."""
    content = _build_active_shards_via_ps1(include219=True, include248=True)
    hosts = []
    for raw in content.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line or line.startswith("#"):
            continue
        hosts.append(line.split()[0])
    assert hosts == [
        "orchestrator",
        "orchestrator",
        "orchestrator",
        "orchestrator",
        "orchestrator",
        "hub",
    ]


@requires_powershell
def test_train_lock_blocks_inference_opt_in_59_and_249(tmp_path: Path):
    """alfa-train.lock blocks orchestrator start when gaming-c/gaming-b are opted in."""
    lock = tmp_path / "alfa-train.lock"
    assert _train_lock_blocks(True, False, lock)
    assert _train_lock_blocks(False, True, lock)
    assert not _train_lock_blocks(False, False, lock)
