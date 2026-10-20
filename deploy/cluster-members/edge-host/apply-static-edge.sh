#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
[ -r "$HERE/alfa-net-exclusive.default" ] && . "$HERE/alfa-net-exclusive.default"
export ETH_CON WIFI_CON ADDR GW DNS ETH_DEV WIFI_DEV EXTRA_WIFI_CON
exec bash "$HERE/../_common/net-exclusive/apply-static.sh"
