#!/usr/bin/env bash
# Fail if the host CPU lacks AVX2. llama-server (rerank sidecar) requires AVX2
# in the CPU backend; without it the binary exits SIGILL (132) immediately after
# ggml_cuda_init on Proxmox guests with default "qemu64" CPU type.
#
# Fix: Proxmox VM100 -> Hardware -> Processors -> Type = host (i5-9600K has AVX2).
# See docs/DOCKGE_100_OPERATOR.md and bootstrap-vm100.sh.
#
# Usage:
#   bash deploy/cluster-members/_common/preflight-cpu-avx2.sh
set -euo pipefail

LABEL="${HOST_LABEL:-$(hostname -s)}"

if grep -q avx2 /proc/cpuinfo 2>/dev/null; then
  echo "preflight-cpu-avx2 OK on $LABEL (AVX2 present)"
  exit 0
fi

echo "ERROR: $LABEL CPU has no AVX2 (llama-server rerank will SIGILL exit 132)." >&2
echo "  Proxmox: set VM CPU type to 'host', reboot guest, re-run deploy-rerank.sh." >&2
echo "  See docs/DOCKGE_100_OPERATOR.md (Proxmox CPU prerequisites)." >&2
exit 1
