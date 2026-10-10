#!/usr/bin/env bash
# Make hub docker-images tarballs readable over SMB for Windows workers.
#
# Share ACL FULL is not enough. hub: share ACL cannot exceed filesystem ACL
# https://www.hub.com/docs/scale/25.10/scaletutorials/shares/smb/
#
# POSIX other-read is required so Samba can serve files created as root
# (docker save). Same chmod as scripts/build-llamacpp-rpc-cuda128-on-hub.sh.
# Filesystem ACL (Edit Filesystem ACL, apply recursively) is still required
# for named users Corey/Colin/cody/operator -- this script prints that reminder.
#
# Usage (on hub as operator):
#   bash scripts/fix-hub-docker-images-smb-read.sh
#   bash scripts/fix-hub-docker-images-smb-read.sh --apply-posix
set -euo pipefail

APPLY=0
if [[ "${1:-}" == "--apply-posix" ]]; then
  APPLY=1
elif [[ -n "${1:-}" ]]; then
  echo "Usage: $0 [--apply-posix]" >&2
  exit 2
fi

HUB_ROOT="${HUB_ROOT:-/mnt/hub/alfa-ai}"
DIR="${HUB_ROOT}/docker-images"
TARBALL="alfa-llamacpp-rpc-cuda128-b10355.tar.gz"

if [[ ! -d "$DIR" ]]; then
  echo "ERROR: missing $DIR" >&2
  exit 1
fi

echo "== POSIX mode (stat) =="
stat -c '%A %U:%G %n' "$DIR" || true
if [[ -f "$DIR/$TARBALL" ]]; then
  stat -c '%A %U:%G %s %n' "$DIR/$TARBALL"
else
  echo "WARN: $DIR/$TARBALL not present"
fi
echo ""
echo "== tarball modes =="
# shellcheck disable=SC2012
ls -l "$DIR"/*.tar.gz 2>/dev/null | head -n 30 || echo "(no tar.gz)"

echo ""
echo "== hub SMB users (Samba Authentication must be on) =="
for u in Corey Colin Cody operator operator operator; do
  if getent passwd "$u" >/dev/null 2>&1; then
    echo "  user OK: $u"
  else
    echo "  user MISSING: $u"
  fi
done

echo ""
echo "== filesystem.getacl (directory) =="
if command -v midclt >/dev/null 2>&1; then
  midclt call filesystem.getacl "{\"path\": \"$DIR\"}" || echo "WARN: filesystem.getacl failed"
else
  echo "(midclt not on PATH)"
fi

if [[ "$APPLY" -eq 1 ]]; then
  echo ""
  echo "== chmod a+rX directory; chmod a+r tarballs + images.json =="
  chmod a+rX "$DIR"
  shopt -s nullglob
  for f in "$DIR"/*.tar.gz "$DIR"/images.json; do
    [[ -e "$f" ]] || continue
    chmod a+r "$f"
    stat -c '  %A %n' "$f"
  done
  echo "POSIX other-read applied."
else
  echo ""
  echo "Inspect only. To apply POSIX other-read: $0 --apply-posix"
fi

echo ""
echo "Still required (hub UI, not this script):"
echo "  Shares -> docker-images -> Edit Filesystem ACL (not Share ACL)"
echo "  ACE per worker user (Corey Colin cody operator) or one group: Read + Inherit"
echo "  Check Apply permissions recursively, then Save Access Control List"
echo "  Docs: https://www.hub.com/docs/scale/datasets/permissions/editaclscreens/"
echo "  Parent dataset Alfa-AI needs Traverse if docker-images is nested."
