#!/bin/bash
# Phases: single-thread and 8-process SHA-256, each at normal priority and under taskpolicy -b.
# Writes "phase start end seconds" lines to phases.txt; 60 s cool-down before each phase.
B=$(dirname "$0"); out=$B/phases.txt; : > $out
phase() {  # name, bg(0/1), procs, rounds
  sleep 60; s=$(date +%s.%N 2>/dev/null || python3 -c 'import time;print(time.time())')
  s=$(python3 -c 'import time;print(f"{time.time():.1f}")')
  pre=""; [ "$2" = 1 ] && pre="taskpolicy -b"
  for i in $(seq "$3"); do $pre python3 -I $B/work.py "$4" > $B/t.$1.$i & done; wait
  e=$(python3 -c 'import time;print(f"{time.time():.1f}")')
  echo "$1 $s $e $(python3 -c "print(f'{$e-$s:.1f}')")" >> $out
}
phase single_normal 0 1 46000
phase single_bg     1 1 46000
phase multi_normal  0 8 12000
phase multi_bg      1 8 12000
echo done >> $out
