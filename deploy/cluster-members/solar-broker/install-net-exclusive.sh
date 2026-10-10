#!/bin/bash
# Pi4 wrapper: host defaults + shared net-exclusive installer.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
export DEFAULT_FILE="$HERE/alfa-net-exclusive.default"
export SRC="$HERE/../_common/net-exclusive"
exec bash "$SRC/install-net-exclusive.sh"
