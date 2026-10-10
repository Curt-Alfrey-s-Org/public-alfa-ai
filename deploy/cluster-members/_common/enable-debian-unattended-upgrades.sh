#!/bin/sh
# Install and enable Debian unattended-upgrades (security, vendor default).
# Official: https://wiki.debian.org/PeriodicUpdates
#           https://ubuntu.com/server/docs/how-to/software/automatic-updates/
# Not for Proxmox VE, Ubuntu (already installed), Mint, or hub.
set -eu

if [ "$(id -u)" -ne 0 ]; then
	echo "enable-debian-unattended-upgrades.sh: run as root" >&2
	exit 1
fi

if [ -d /etc/pve ]; then
	echo "enable-debian-unattended-upgrades.sh: refuse on Proxmox VE" >&2
	exit 1
fi
if grep -qi hub /etc/os-release 2>/dev/null; then
	echo "enable-debian-unattended-upgrades.sh: refuse on hub" >&2
	exit 1
fi
if grep -qi linuxmint /etc/os-release 2>/dev/null; then
	echo "enable-debian-unattended-upgrades.sh: refuse on Linux Mint" >&2
	exit 1
fi
if grep -q '^ID=ubuntu$' /etc/os-release 2>/dev/null; then
	echo "enable-debian-unattended-upgrades.sh: Ubuntu already ships unattended-upgrades; use install-alfa-unattended-policy.sh" >&2
	exit 1
fi
if ! grep -q '^ID=debian$' /etc/os-release 2>/dev/null; then
	echo "enable-debian-unattended-upgrades.sh: only for Debian" >&2
	exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y unattended-upgrades
echo 'unattended-upgrades unattended-upgrades/enable_auto_updates boolean true' | debconf-set-selections
dpkg-reconfigure -f noninteractive unattended-upgrades
echo "unattended-upgrades installed and auto-updates enabled"
