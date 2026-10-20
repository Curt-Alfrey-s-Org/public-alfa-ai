"""Secret filename denylist for the from-scratch corpus.

Content patterns stay in scripts/scan_pass_jsonl.py. This module adds the
plan's file rules: .env, *.env, TLS/private keys, and user_settings.py when
that file's text matches the secret scanner.
"""

from __future__ import annotations

import fnmatch
from collections.abc import Callable

# Plan denylist plus private key filenames the 7B corpus yaml already treats
# as key material (*.pem / *.key). user_settings.py is decided by content.
PLAN_NAME_GLOBS: tuple[str, ...] = (
    ".env",
    ".env.*",
    "*.env",
    "*.pem",
    "*.key",
    "*.p12",
    "*.pfx",
    "*.crt",
    "id_rsa",
    "id_ed25519",
    "id_ecdsa",
    "id_dsa",
)

USER_SETTINGS_NAME = "user_settings.py"


def name_matches(filename: str, patterns: list[str]) -> bool:
    for pattern in patterns:
        if fnmatch.fnmatch(filename, pattern):
            return True
        if fnmatch.fnmatch(filename.lower(), pattern.lower()):
            return True
    return False


def is_secret_filename(filename: str, extra_globs: list[str] | None = None) -> bool:
    patterns = list(PLAN_NAME_GLOBS)
    if extra_globs:
        patterns.extend(extra_globs)
    return name_matches(filename, patterns)


def user_settings_has_credentials(
    filename: str,
    text: str,
    scan_text: Callable[[str], list],
) -> bool:
    if filename != USER_SETTINGS_NAME:
        return False
    return bool(scan_text(text))
