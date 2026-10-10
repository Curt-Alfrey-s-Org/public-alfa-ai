#!/usr/bin/env bash
# Guard: every .ps1 in deploy/cluster-members and scripts/ must be pure ASCII.
# Windows PowerShell 5 reads .ps1 files as the current ANSI code page when
# there is no UTF-8 BOM. Multi-byte UTF-8 characters (em dash, curly quotes,
# ellipsis, ...) inside a string literal break the parser with cascading
# "missing terminator", "missing }", and "array index expression" errors.
# Keeping these scripts ASCII-only makes them parse identically on every
# Windows worker regardless of code page or BOM.
#
# Usage: bash scripts/check-ps1-ascii.sh
# Exit non-zero and print offenders when any non-ASCII byte is found.

set -euo pipefail
cd "$(dirname "$0")/.."

mapfile -t files < <(find deploy/cluster-members scripts -name '*.ps1' 2>/dev/null)
if [ "${#files[@]}" -eq 0 ]; then
    echo "no .ps1 files found under deploy/cluster-members or scripts/"
    exit 0
fi

bad=0
for f in "${files[@]}"; do
    if LC_ALL=C grep -qP '[^\x00-\x7F]' "$f"; then
        echo "NON-ASCII: $f"
        LC_ALL=C grep -nP '[^\x00-\x7F]' "$f" | head -5 | sed 's/^/    /'
        bad=1
    fi
done

if [ "$bad" -ne 0 ]; then
    echo ""
    echo "Fix with scripts/normalize-ps1-ascii.py (see header of this file for rationale)."
    exit 1
fi
echo "All .ps1 files are pure ASCII (${#files[@]} files checked)."
