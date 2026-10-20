# Summarise powermetrics (pm<run>.txt) + temps<run>.txt over each phase window.
# Usage: analyze.py <dir> [phases file] [run suffix, e.g. 2 for pm2.txt/temps2.txt]
import re, sys, datetime, statistics as st
B = sys.argv[1]
RUN = sys.argv[3] if len(sys.argv) > 3 else ""
samples = []  # (epoch, cpu_mW, e_res, p0_res, p1_res, e_mhz, p_mhz)
cur = None
for line in open(f"{B}/pm{RUN}.txt", errors="replace"):
    m = re.search(r"Sampled system activity \((.+?)\) \(", line)
    if m:
        if cur and "cpu" in cur: samples.append(cur)
        t = datetime.datetime.strptime(m.group(1), "%a %b %d %H:%M:%S %Y %z").timestamp()
        cur = {"t": t}; continue
    if cur is None: continue
    for key, pat in [("e", r"^E-Cluster HW active residency:\s+([\d.]+)%"), ("p0", r"^P0-Cluster HW active residency:\s+([\d.]+)%"),
                     ("p1", r"^P1-Cluster HW active residency:\s+([\d.]+)%"), ("cpu", r"^CPU Power: (\d+) mW"),
                     ("emhz", r"^E-Cluster HW active frequency: (\d+)"), ("p0mhz", r"^P0-Cluster HW active frequency: (\d+)")]:
        m = re.search(pat, line)
        if m: cur[key] = float(m.group(1))
if cur and "cpu" in cur: samples.append(cur)
temps = [tuple(map(float, l.split())) for l in open(f"{B}/temps{RUN}.txt") if len(l.split()) == 2]
phases = [l.split() for l in open(f"{B}/{sys.argv[2] if len(sys.argv) > 2 else 'phases.txt'}") if len(l.split()) >= 3]
print("phase seconds cpuW energyJ Eact% P0act% P1act% Emhz P0mhz tempMean tempPeak n")
for p in phases:
    name, s, e = p[0], float(p[1]), float(p[2])
    w = [x for x in samples if s + 0.5 <= x["t"] <= e + 0.5]
    tt = [v for (t, v) in temps if s <= t <= e]
    if not w: print(name, "no samples"); continue
    mean = lambda k: st.mean(x.get(k, 0) for x in w)
    cpu = mean("cpu") / 1000
    print(f"{name} {e-s:.1f} {cpu:.2f} {cpu*(e-s):.0f} {mean('e'):.0f} {mean('p0'):.0f} {mean('p1'):.0f} "
          f"{mean('emhz'):.0f} {mean('p0mhz'):.0f} {st.mean(tt) if tt else 0:.1f} {max(tt) if tt else 0:.1f} {len(w)}")
