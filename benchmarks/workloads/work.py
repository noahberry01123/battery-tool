# Fixed CPU workload: N rounds of SHA-256 over 1 MiB.
# Prints: wall seconds, CPU seconds, share of CPU time on performance cores, energy (J),
# all for this process, from proc_pid_rusage(RUSAGE_INFO_V6) via ctypes.
import ctypes, hashlib, os, sys, time

def rusage():
    buf = (ctypes.c_uint64 * 64)()                       # 16-byte uuid + uint64 fields (v6 fits)
    libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    if libc.proc_pid_rusage(os.getpid(), 6, ctypes.byref(buf)) != 0:
        return None
    f = list(buf)[2:]                                     # skip the uuid (2 x uint64)
    tb = (ctypes.c_uint32 * 2)(); libc.mach_timebase_info(ctypes.byref(tb))
    ns = tb[0] / tb[1]
    return {"cpu": (f[0] + f[1]) * ns / 1e9, "pcpu": (f[36] + f[37]) * ns / 1e9, "energy": f[40] / 1e9}

n = int(sys.argv[1]); buf = b"x" * (1 << 20); t = time.time()
for _ in range(n): hashlib.sha256(buf).digest()
wall = time.time() - t; r = rusage()
if r:
    print(f"{wall:.2f} cpu={r['cpu']:.2f} pshare={r['pcpu'] / max(r['cpu'], 1e-9):.3f} energy_j={r['energy']:.2f}")
else:
    print(f"{wall:.2f}")
