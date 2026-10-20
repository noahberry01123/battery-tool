# Light, bursty background load: every <period> s, do <rounds> SHA-256 hashes of 1 MiB (fixed WORK per burst,
# so every mode does the same work; a slower core just takes longer). If a burst outlasts the period the next
# starts at once. 700 rounds ~ 0.3 s on one M1 Pro performance core. Runs for <duration> s; prints bursts done.
import hashlib, sys, time
duration, period, rounds = float(sys.argv[1]), float(sys.argv[2]), int(sys.argv[3])
buf = b"x" * (1 << 20); end = time.time() + duration; done = 0
while time.time() < end:
    t = time.time()
    for _ in range(rounds):
        hashlib.sha256(buf).digest()
    done += 1
    time.sleep(max(0, period - (time.time() - t)))
print(f"bursts={done} rounds_per_burst={rounds}")
