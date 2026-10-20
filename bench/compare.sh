#!/bin/bash
# Run as root (sudo bench/compare.sh <your user name>). Same apps open: off / macOS Low Power Mode
# only / Extreme LPM, twice, alternating, 20 s settle + 180 s measured each.
# Writes compare.txt ("phase start end") and pm2.txt (powermetrics). Restores the auto-trigger at 30 °C.
# Time the fixed workload under plain Low Power Mode from your own shell, not from here:
# jobs started from a root/osascript shell ran ~3x slower in testing.
cd /
B=$(cd "$(dirname "$0")" && pwd); U=$1; BT=/usr/local/bin/battery-tool; out=$B/compare.txt; : > $out
asuser() { sudo -u "$U" "$@"; }
asuser $BT lowpower auto off >/dev/null; asuser $BT lowpower off >/dev/null; pmset -a lowpowermode 0
/usr/bin/powermetrics -i 1000 -n 1500 --samplers cpu_power -o $B/pm2.txt >/dev/null 2>&1 & PM=$!
measure() { sleep 20; s=$(date +%s); sleep 180; e=$(date +%s); echo "$1 $s $e" >> $out; }
for r in 1 2; do
  asuser $BT lowpower off >/dev/null; pmset -a lowpowermode 0; measure off_$r
  pmset -a lowpowermode 1; measure lpm_$r
  pmset -a lowpowermode 0; asuser $BT lowpower on >/dev/null; measure extreme_$r
  asuser $BT lowpower off >/dev/null
done
pmset -a lowpowermode 0; kill $PM 2>/dev/null
asuser $BT lowpower auto on 30 >/dev/null
