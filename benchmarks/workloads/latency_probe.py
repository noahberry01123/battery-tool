# Timer-wakeup latency probe: repeatedly sleeps 10 ms and prints how late it woke up (ms),
# one value per line, until killed or N samples. A proxy for how responsive an eligible
# (demotable) process is while other work competes for the CPU; not a UI latency measurement.
import sys, time
n = int(sys.argv[1]) if len(sys.argv) > 1 else 2000
for _ in range(n):
    t = time.perf_counter(); time.sleep(0.010)
    print(f"{(time.perf_counter() - t - 0.010) * 1000:.3f}", flush=True)
