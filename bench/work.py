# Fixed CPU workload: N rounds of SHA-256 over 1 MiB. Prints wall seconds.
import hashlib, sys, time
n = int(sys.argv[1]); buf = b"x" * (1 << 20); t = time.time()
for _ in range(n): hashlib.sha256(buf).digest()
print(f"{time.time() - t:.2f}")
