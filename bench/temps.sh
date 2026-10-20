#!/bin/bash
# Every second: epoch and the hottest CPU sensor (Tp* SMC keys). Runs until killed.
# Uses the MacFanCtl CLI to read the sensors; set MACFANCTL to its path.
F=${MACFANCTL:-../macfanctl/macfanctl}
while true; do
  m=0; for k in Tp01 Tp05 Tp09 Tp0D Tp0H Tp0L Tp0P Tp0T Tp0X Tp0b Tp02 Tp06 Tp0A Tp0E Tp0I Tp0M Tp0Q Tp0U Tp0Y Tp0c; do
    v=$($F get $k 2>/dev/null | sed -n 's/.*value=//p'); [ -n "$v" ] && m=$(echo "$v $m" | awk '{print ($1>$2)?$1:$2}'); done
  echo "$(date +%s) $m"; sleep 1
done
