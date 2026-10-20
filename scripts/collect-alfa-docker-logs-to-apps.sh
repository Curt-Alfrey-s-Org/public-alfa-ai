#!/usr/bin/env bash
# DEPRECATED (Jul 2026): log hub moved to inference — use collect-alfa-docker-logs-to-148.sh
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/collect-alfa-docker-logs-to-148.sh" "$@"