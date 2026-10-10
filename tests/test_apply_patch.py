"""Tests for apply_patch host action (Wave E)."""

from __future__ import annotations

import pytest

from src.ops.host_catalog import validate_proposal


def test_apply_patch_blocks_env_path() -> None:
    with pytest.raises(ValueError, match="blocked"):
        validate_proposal(
            "apply_patch",
            "106",
            {"relative_path": ".env", "content": "KEY=val\n"},
            {},
            enforce_enabled=False,
        )


def test_apply_patch_accepts_small_file() -> None:
    spec, host_cfg, norm = validate_proposal(
        "apply_patch",
        "106",
        {"relative_path": "api/foo.py", "content": "x = 1\n"},
        {},
        enforce_enabled=False,
    )
    assert spec.key == "apply_patch"
    assert host_cfg["key"] == "106"
    assert norm["relative_path"] == "api/foo.py"
