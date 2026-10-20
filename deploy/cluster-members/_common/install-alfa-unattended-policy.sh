#!/bin/sh
# Install ALFa unattended-upgrades overlay (Ubuntu Server / Debian).
# Official: https://ubuntu.com/server/docs/how-to/software/automatic-updates/
# Not for Proxmox, hub, or Linux Mint.
set -eu

if [ "$(id -u)" -ne 0 ]; then
	echo "install-alfa-unattended-policy.sh: run as root" >&2
	exit 1
fi

if [ -d /etc/pve ]; then
	echo "install-alfa-unattended-policy.sh: refuse on Proxmox VE" >&2
	exit 1
fi
if grep -qi hub /etc/os-release 2>/dev/null; then
	echo "install-alfa-unattended-policy.sh: refuse on hub" >&2
	exit 1
fi
if grep -qi linuxmint /etc/os-release 2>/dev/null; then
	echo "install-alfa-unattended-policy.sh: refuse on Linux Mint (use mintupdate)" >&2
	exit 1
fi

HERE="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
SRC_APT="$HERE/apt/51alfa-unattended"
SRC_NR="$HERE/needrestart/50-alfa-list-only.conf"
if [ ! -f "$SRC_APT" ]; then
	echo "missing $SRC_APT" >&2
	exit 1
fi
if [ ! -f "$SRC_NR" ]; then
	echo "missing $SRC_NR" >&2
	exit 1
fi

if ! dpkg-query -W unattended-upgrades >/dev/null 2>&1; then
	echo "unattended-upgrades is not installed; install it from the vendor repo first" >&2
	exit 1
fi

cp "$SRC_APT" /etc/apt/apt.conf.d/51alfa-unattended
chmod 644 /etc/apt/apt.conf.d/51alfa-unattended
echo "installed /etc/apt/apt.conf.d/51alfa-unattended"

if [ -d /etc/needrestart/conf.d ]; then
	cp "$SRC_NR" /etc/needrestart/conf.d/50-alfa-list-only.conf
	chmod 644 /etc/needrestart/conf.d/50-alfa-list-only.conf
	echo "installed /etc/needrestart/conf.d/50-alfa-list-only.conf"
else
	echo "needrestart conf.d missing; skipped list-only drop-in"
fi
