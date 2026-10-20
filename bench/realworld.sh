#!/bin/bash
# Same open apps, Extreme Low Power Mode off → on → off, 180 s measured each after a 20 s settle.
B=$(dirname "$0"); out=$B/realworld.txt; : > $out
now() { python3 -c 'import time;print(f"{time.time():.1f}")'; }
run() {  # name, on|off
  /usr/local/bin/battery-tool lowpower "$2" > /dev/null; sleep 20
  n=$(/usr/local/bin/battery-tool lowpower status 2>/dev/null | grep -o '[0-9]* processes' | head -1)
  s=$(now); sleep 180; e=$(now); echo "$1 $s $e ${n:-0 processes}" >> $out
}
run idle_off_1 off
run idle_on on
run idle_off_2 off
echo done >> $out
