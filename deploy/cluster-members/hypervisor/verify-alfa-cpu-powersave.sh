#!/bin/sh
set -eu
echo GOV
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor | sort | uniq -c
echo EPP
cat /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference | sort | uniq -c
RAPL=/sys/class/powercap/intel-rapl:0/energy_uj
e1=$(cat "$RAPL")
sleep 2
e2=$(cat "$RAPL")
echo RAPL_mW=$(( (e2 - e1) / 2000 ))
systemctl is-enabled alfa-cpu-powersave.service
systemctl is-active alfa-cpu-powersave.service
