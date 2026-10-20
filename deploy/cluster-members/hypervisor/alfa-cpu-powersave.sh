#!/bin/sh
# Set intel_pstate HWP idle policy on pve-i5 (hypervisor).
# Official: https://docs.kernel.org/admin-guide/pm/intel_pstate.html
# HWP + governor "performance" locks EPP to 0 (max P-state). Use powersave
# first, then energy_performance_preference=balance_performance (same as inference).
set -eu

for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
	echo powersave >"$gov"
done

for epp in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
	echo balance_performance >"$epp"
done
