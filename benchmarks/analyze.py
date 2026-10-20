#!/opt/homebrew/bin/python3
"""Analyse one benchmark run (results/<run_id>): per-window metrics, per-condition statistics, charts.

Unit of replication = one measured window (one condition x scenario x round), never a telemetry sample.
Writes into the run folder: windows_metrics.csv, summary.csv, summary.md, figures/*.png
Usage: analyze.py results/<run_id>
"""
import csv, glob, math, os, plistlib, re, statistics as st, sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

RUN = sys.argv[1]
FIG = os.path.join(RUN, "figures"); os.makedirs(FIG, exist_ok=True)
ORDER = ["normal", "lowpower", "extreme"]
LABEL = {"normal": "Normal", "lowpower": "Low Power Mode", "extreme": "Extreme LPM"}
COLOR = {"normal": "#8a8f98", "lowpower": "#5b7fa6", "extreme": "#1f6feb"}
T95 = {1: 12.71, 2: 4.30, 3: 3.18, 4: 2.78, 5: 2.57, 6: 2.45, 7: 2.36, 8: 2.31, 9: 2.26}


def display_events():
    """(epoch, 'on'|'off') display events: from <run>/display_events.txt if the runner saved them, else pmset -g log."""
    import datetime as dt, subprocess
    p = os.path.join(RUN, "display_events.txt")
    text = open(p).read() if os.path.exists(p) else subprocess.run(["pmset", "-g", "log"], capture_output=True, text=True).stdout
    ev = []
    for l in text.splitlines():
        m = re.match(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) [+-]\d{4} Notification\s+Display is turned (on|off)", l)
        if m:
            ev.append((dt.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S").timestamp(), m.group(2)))
    return sorted(ev)


EVENTS = display_events()


def display_on_fraction(a, b):
    """Share of [a, b] with the display on, from the event log (assumes 'on' before the first event)."""
    def state(t):
        s = "on"
        for e, v in EVENTS:
            if e <= t:
                s = v
            else:
                break
        return s
    pts = [a] + [e for e, _ in EVENTS if a < e < b] + [b]
    return sum(p2 - p1 for p1, p2 in zip(pts, pts[1:]) if state(p1) == "on") / (b - a)


def num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


# ---------- load ----------
WIN = "windows_recovered.csv" if os.path.exists(os.path.join(RUN, "windows_recovered.csv")) else "windows.csv"
windows = list(csv.DictReader(open(os.path.join(RUN, WIN))))
tel = [r for r in csv.DictReader(open(os.path.join(RUN, "telemetry.csv")))]
for r in tel:
    for k in list(r):
        r[k] = num(r[k])


def tel_between(a, b):
    return [r for r in tel if r["epoch"] is not None and a <= r["epoch"] <= b]


def integrate(rows, key):
    """Trapezoid energy (J) of a power column over the rows' timestamps."""
    pts = [(r["epoch"], r[key]) for r in rows if r[key] is not None]
    return sum((t2 - t1) * (v1 + v2) / 2 for (t1, v1), (t2, v2) in zip(pts, pts[1:])) if len(pts) > 1 else None


def procs(path):
    out = {}
    if not os.path.exists(path):
        return out
    rows = [l for l in open(path) if not l.startswith("#")]
    for r in csv.DictReader(rows):
        out[(r["pid"], r["start_sec"])] = r
    return out


def pm_window(w):
    """Mean of powermetrics samples in pm/<w>.plist (NUL-separated plists)."""
    p = os.path.join(RUN, "pm", f"{w}.plist")
    if not os.path.exists(p):
        return {}
    acc = {"cpu_w": [], "gpu_w": [], "e_active": [], "p_active": [], "e_mhz": [], "p_mhz": []}
    for chunk in open(p, "rb").read().split(b"\x00"):
        chunk = chunk.strip()
        if not chunk:
            continue
        try:
            d = plistlib.loads(chunk)
        except Exception:
            continue
        pr = d.get("processor", {})
        if "cpu_energy" in pr and d.get("elapsed_ns"):
            acc["cpu_w"].append(pr["cpu_energy"] / 1000 / (d["elapsed_ns"] / 1e9))   # mJ -> W
        elif "cpu_power" in pr:
            acc["cpu_w"].append(pr["cpu_power"] / 1000)
        g = d.get("gpu", {})
        if "gpu_energy" in g and d.get("elapsed_ns"):
            acc["gpu_w"].append(g["gpu_energy"] / 1000 / (d["elapsed_ns"] / 1e9))
        for cl in pr.get("clusters", []):
            busy = 100 * (1 - cl.get("idle_ratio", 1))
            if cl["name"].startswith("E"):
                acc["e_active"].append(busy); acc["e_mhz"].append(cl.get("freq_hz", 0) / 1e6)
            elif cl["name"].startswith("P"):
                acc["p_active"].append(busy); acc["p_mhz"].append(cl.get("freq_hz", 0) / 1e6)
    return {k: (st.mean(v) if v else None) for k, v in acc.items()}


# ---------- per window ----------
rows = []
for w in windows:
    a, b = float(w["start"]), float(w["end"])
    t = tel_between(a, b)
    m = {"window": w["window"], "condition": w["condition"], "scenario": w["scenario"], "rep": int(w["rep"]),
         "seconds": float(w["seconds"]), "result": w["result"], "n_telemetry": len(t)}
    for k, col in [("system_w", "system_w"), ("battery_w", "battery_w"), ("cpu_c", "cpu_max_c"), ("gpu_c", "gpu_max_c"),
                   ("batt_c", "batt0_c"), ("palm0_c", "palm0_c"), ("palm1_c", "palm1_c"), ("fan0_rpm", "fan0_rpm")]:
        v = [r[col] for r in t if r[col] is not None]
        m[k] = st.mean(v) if v else None
        if k == "cpu_c":
            m["cpu_c_peak"] = max(v) if v else None
    m["system_j"] = integrate(t, "system_w")
    m["battery_j"] = integrate(t, "battery_w")
    m["display_on"] = display_on_fraction(a, b)
    # Whole-system power depends on the display (~4-5 W here), so compare it only between windows in the same state.
    for k in ("system_w", "system_j"):
        m[f"{k}_dispon"] = m[k] if m["display_on"] >= 0.9 else None
        m[f"{k}_dispoff"] = m[k] if m["display_on"] <= 0.1 else None
    for part in w["result"].split():                             # job_s=12.34 pshare=0.001 ...
        if "=" in part:
            k, v = part.split("=", 1); m[k] = num(v)
    s, e = procs(os.path.join(RUN, "procs", f"{w['window']}_start.csv")), procs(os.path.join(RUN, "procs", f"{w['window']}_end.csv"))
    tot = {"all": [0, 0], "demoted": [0, 0], "other": [0, 0]}
    n_e = n_p = n_active = 0
    for key, r1 in e.items():
        r0 = s.get(key)
        if not r0:
            continue
        dc = float(r1["cpu_ns"]) - float(r0["cpu_ns"]); dp = float(r1["pcore_ns"]) - float(r0["pcore_ns"])
        if dc <= 0:
            continue
        grp = "demoted" if r1["ext_darwin_bg"] == "1" else "other"
        for g in ("all", grp):
            tot[g][0] += dc; tot[g][1] += dp
        if dc > 10e6:                                           # > 10 ms CPU in the window
            n_active += 1
            share = dp / dc
            n_e += share < 0.10; n_p += share > 0.90
    for g, (c, p) in tot.items():
        m[f"cpu_s_{g}"] = c / 1e9
        m[f"pshare_{g}"] = p / c if c else None
    m["procs_active"], m["procs_mostly_e"], m["procs_mostly_p"] = n_active, n_e, n_p
    m["procs_demoted"] = sum(1 for r in e.values() if r["ext_darwin_bg"] == "1")
    for key, r1 in e.items():                                   # Battery Tool's own daemon (root) overhead
        if r1["name"] == "battery-tool" and r1["uid"] == "0" and key in s:
            secs = float(w["seconds"])
            m["daemon_cpu_pct"] = 100 * (float(r1["cpu_ns"]) - float(s[key]["cpu_ns"])) / 1e9 / secs
            m["daemon_w"] = (float(r1["energy_nj"]) - float(s[key]["energy_nj"])) / 1e9 / secs
    m.update(pm_window(w["window"]))
    lat = os.path.join(RUN, "latency", f"{w['window']}.txt")
    if os.path.exists(lat):
        v = sorted(float(x) for x in open(lat) if x.strip())
        if v:
            m["lat_median_ms"] = v[len(v) // 2]; m["lat_p95_ms"] = v[int(len(v) * 0.95) - 1]; m["lat_n"] = len(v)
    rows.append(m)

keys = sorted({k for r in rows for k in r}, key=lambda k: (k not in ("window", "condition", "scenario", "rep"), k))
with open(os.path.join(RUN, "windows_metrics.csv"), "w", newline="") as f:
    wr = csv.DictWriter(f, fieldnames=keys); wr.writeheader(); wr.writerows(rows)


# ---------- statistics across rounds ----------
def stats(vals):
    v = [x for x in vals if x is not None and not math.isnan(x)]
    if not v:
        return None
    n = len(v); mean = st.mean(v); sd = st.stdev(v) if n > 1 else 0.0
    ci = T95.get(n - 1, 2.0) * sd / math.sqrt(n) if n > 1 else None
    return {"n": n, "mean": mean, "median": st.median(v), "sd": sd, "min": min(v), "max": max(v), "ci95": ci}


METRICS = ["system_w", "cpu_w", "gpu_w", "cpu_c", "cpu_c_peak", "batt_c", "palm0_c", "palm1_c", "p_active", "e_active",
           "p_mhz", "e_mhz", "pshare_all", "pshare_demoted", "pshare_other", "procs_demoted", "procs_mostly_e",
           "procs_mostly_p", "job_s", "pshare", "system_j", "lat_median_ms", "lat_p95_ms", "daemon_cpu_pct", "daemon_w",
           "battery_w", "battery_j", "procs_active", "display_on", "system_w_dispon", "system_w_dispoff",
           "system_j_dispon", "system_j_dispoff"]
summary = []
for sc in sorted({r["scenario"] for r in rows}):
    for c in ORDER:
        sel = [r for r in rows if r["scenario"] == sc and r["condition"] == c]
        if not sel:
            continue
        for k in METRICS:
            s_ = stats([r.get(k) for r in sel])
            if s_:
                summary.append({"scenario": sc, "condition": c, "metric": k, **s_})
with open(os.path.join(RUN, "summary.csv"), "w", newline="") as f:
    wr = csv.DictWriter(f, fieldnames=["scenario", "condition", "metric", "n", "mean", "median", "sd", "min", "max", "ci95"])
    wr.writeheader(); wr.writerows(summary)


def get(sc, c, k):
    for s_ in summary:
        if s_["scenario"] == sc and s_["condition"] == c and s_["metric"] == k:
            return s_
    return None


# ---------- charts ----------
plt.rcParams.update({"font.size": 10, "axes.spines.top": False, "axes.spines.right": False, "figure.dpi": 150})
N = max((s_["n"] for s_ in summary), default=0)
NOTE = f"MacBookPro18,3 (M1 Pro 8P+2E), macOS 26.6.2, on AC with charging held, fans fixed at max. n = rounds per bar; error bars = SD."


def bars(sc, k, title, ylabel, fname, fmt="{:.2f}", scale=1.0):
    fig, ax = plt.subplots(figsize=(6.4, 3.8))
    xs, ys, es, ns = [], [], [], []
    for c in ORDER:
        s_ = get(sc, c, k)
        if s_:
            xs.append(LABEL[c]); ys.append(s_["mean"] * scale); es.append(s_["sd"] * scale); ns.append(s_["n"])
    if not xs:
        plt.close(fig); return
    b = ax.bar(xs, ys, yerr=es, capsize=4, color=[COLOR[c] for c in ORDER if get(sc, c, k)])
    for rect, y, n in zip(b, ys, ns):
        ax.annotate(fmt.format(y) + f"\nn={n}", (rect.get_x() + rect.get_width() / 2, y), ha="center", va="bottom",
                    xytext=(0, 4), textcoords="offset points", fontsize=8)
    ax.set_ylabel(ylabel); ax.set_title(title, loc="left", fontsize=11, fontweight="bold")
    ax.set_ylim(0, max(y + e for y, e in zip(ys, es)) * 1.3 or 1)
    fig.text(0.01, 0.01, NOTE, fontsize=6.5, color="#666")
    fig.tight_layout(rect=(0, 0.04, 1, 1)); fig.savefig(os.path.join(FIG, fname)); plt.close(fig)


def stacked_pe(sc, fname, title):
    """Share of user-process CPU time on P vs E cores, per condition (proc_pid_rusage deltas; processes alive for the whole window)."""
    fig, ax = plt.subplots(figsize=(6.4, 3.8))
    labels, p, e = [], [], []
    for c in ORDER:
        s_ = get(sc, c, "pshare_all")
        if s_:
            labels.append(LABEL[c]); p.append(100 * s_["mean"]); e.append(100 - 100 * s_["mean"])
    if not labels:
        plt.close(fig); return
    ax.bar(labels, p, color="#d97706", label="on performance cores")
    ax.bar(labels, e, bottom=p, color="#1f6feb", label="on efficiency cores")
    for i, (pv, ev) in enumerate(zip(p, e)):
        ax.text(i, pv / 2, f"{pv:.0f}%", ha="center", va="center", color="white", fontsize=9, fontweight="bold")
        ax.text(i, pv + ev / 2, f"{ev:.0f}%", ha="center", va="center", color="white", fontsize=9, fontweight="bold")
    ax.set_ylabel("Share of user-process CPU time (%)"); ax.set_ylim(0, 100)
    ax.set_title(title, loc="left", fontsize=11, fontweight="bold"); ax.legend(frameon=False, fontsize=8, loc="upper right")
    fig.text(0.01, 0.01, NOTE + " Source: proc_pid_rusage v6; your user's processes alive for the whole window (root processes not readable).", fontsize=6.5, color="#666")
    fig.tight_layout(rect=(0, 0.04, 1, 1)); fig.savefig(os.path.join(FIG, fname)); plt.close(fig)


for sc in sorted({r["scenario"] for r in rows}):
    stacked_pe(sc, f"{sc}_cpu_time_p_vs_e.png", f"Where CPU time ran ({sc})")
    bars(sc, "system_w", f"Total system power ({sc})", "W (SMC PSTR)", f"{sc}_system_power.png")
    bars(sc, "cpu_w", f"CPU power ({sc})", "W (powermetrics)", f"{sc}_cpu_power.png")
    bars(sc, "cpu_c", f"Hottest CPU sensor, mean ({sc})", "°C", f"{sc}_cpu_temp.png", "{:.1f}")
    bars(sc, "p_active", f"Performance cluster busy ({sc})", "% of time active", f"{sc}_p_active.png", "{:.0f}")
for sc in ("bg_single", "bg_multi"):
    bars(sc, "job_s", f"Time to finish the background job ({sc})", "seconds", f"{sc}_job_time.png", "{:.1f}")
    bars(sc, "system_j", f"Whole-system energy during the job ({sc})", "J (integral of PSTR)", f"{sc}_job_energy.png", "{:.0f}")
bars("bg_multi", "lat_p95_ms", "Timer-wakeup latency of an eligible process, p95 (8 jobs running)", "ms late", "bg_multi_latency_p95.png", "{:.1f}")

# grouped: one metric across scenarios, three bars per scenario
def grouped(k, ylabel, title, fname, scenarios=("idle", "sustained8", "bg_single", "bg_multi"), fmt="{:.1f}", scale=1.0):
    scs = [sc for sc in scenarios if any(get(sc, c, k) for c in ORDER)]
    if not scs:
        return
    fig, ax = plt.subplots(figsize=(8, 3.9)); width = 0.26
    for i, c in enumerate(ORDER):
        have = [get(sc, c, k) is not None for sc in scs]
        ys = [get(sc, c, k)["mean"] * scale if h else 0 for sc, h in zip(scs, have)]
        es = [get(sc, c, k)["sd"] * scale if h else 0 for sc, h in zip(scs, have)]
        xs = [j + (i - 1) * width for j in range(len(scs))]
        ax.bar([x for x, h in zip(xs, have) if h], [y for y, h in zip(ys, have) if h], width,
               yerr=[e for e, h in zip(es, have) if h], capsize=3, color=COLOR[c], label=LABEL[c], error_kw={"elinewidth": 0.8})
        for x, y, e, h in zip(xs, ys, es, have):
            ax.text(x, (y + e) if h else 0, fmt.format(y) if h else "no data", ha="center", va="bottom", fontsize=7,
                    color="#222" if h else "#999", rotation=0 if h else 90)
    ax.set_xticks(range(len(scs))); ax.set_xticklabels([{"idle": "idle (apps open)", "sustained8": "8 jobs, 90 s",
        "bg_single": "1 job (fixed work)", "bg_multi": "8 jobs (fixed work)"}.get(sc, sc) for sc in scs])
    ax.set_ylabel(ylabel); ax.set_title(title, loc="left", fontsize=11, fontweight="bold"); ax.legend(frameon=False, fontsize=8)
    fig.text(0.01, 0.01, NOTE, fontsize=6.5, color="#666"); fig.tight_layout(rect=(0, 0.04, 1, 1))
    fig.savefig(os.path.join(FIG, fname)); plt.close(fig)


grouped("system_w", "W (SMC PSTR)", "Total system power by scenario (all windows; display state mixed)", "all_system_power.png")
grouped("system_w_dispon", "W (SMC PSTR)", "Total system power by scenario, display on", "all_system_power_display_on.png")
grouped("system_w_dispoff", "W (SMC PSTR)", "Total system power by scenario, display off", "all_system_power_display_off.png")
grouped("cpu_w", "W (powermetrics)", "CPU power by scenario", "all_cpu_power.png")
grouped("cpu_c", "°C", "Hottest CPU sensor (mean) by scenario", "all_cpu_temp.png")
grouped("p_active", "% of time active", "Performance cores busy (mean of P0/P1 clusters)", "all_p_cluster_busy.png")
grouped("e_active", "% of time active", "Efficiency cores busy", "all_e_cluster_busy.png")

# processes by where they ran (idle window)
fig, ax = plt.subplots(figsize=(6.4, 3.8)); width = 0.36
labels = [LABEL[c] for c in ORDER if get("idle", c, "procs_mostly_e")]
e_ = [get("idle", c, "procs_mostly_e")["mean"] for c in ORDER if get("idle", c, "procs_mostly_e")]
p_ = [get("idle", c, "procs_mostly_p")["mean"] for c in ORDER if get("idle", c, "procs_mostly_e")]
if labels:
    ax.bar([i - width / 2 for i in range(len(labels))], e_, width, color="#1f6feb", label=">90% of CPU time on efficiency cores")
    ax.bar([i + width / 2 for i in range(len(labels))], p_, width, color="#d97706", label=">90% on performance cores")
    for i, (a_, b_) in enumerate(zip(e_, p_)):
        ax.text(i - width / 2, a_, f"{a_:.0f}", ha="center", va="bottom", fontsize=8); ax.text(i + width / 2, b_, f"{b_:.0f}", ha="center", va="bottom", fontsize=8)
    ax.set_xticks(range(len(labels))); ax.set_xticklabels(labels); ax.set_ylabel("user processes (mean per window)")
    ax.set_title("Where active user processes ran, idle with apps open", loc="left", fontsize=11, fontweight="bold")
    ax.legend(frameon=False, fontsize=8); fig.text(0.01, 0.01, NOTE + " Active = >10 ms CPU in the window.", fontsize=6.5, color="#666")
    fig.tight_layout(rect=(0, 0.04, 1, 1)); fig.savefig(os.path.join(FIG, "idle_processes_by_core.png"))
plt.close(fig)

# job: share of the job's own CPU time on P-cores (self-reported) — the clearest routing evidence
grouped("pshare", "% of the job's CPU time on P-cores", "Background job: share of its own CPU time on performance cores", "job_pcore_share.png",
        scenarios=("bg_single", "bg_multi"), fmt="{:.0f}%", scale=100)

# time series of system power across the whole run, shaded by condition
fig, ax = plt.subplots(figsize=(9, 3.4))
t0 = tel[0]["epoch"]
ax.plot([(r["epoch"] - t0) / 60 for r in tel if r["system_w"] is not None], [r["system_w"] for r in tel if r["system_w"] is not None],
        lw=0.7, color="#444")
for w in windows:
    ax.axvspan((float(w["start"]) - t0) / 60, (float(w["end"]) - t0) / 60, color=COLOR[w["condition"]], alpha=0.18, lw=0)
for c in ORDER:
    ax.plot([], [], color=COLOR[c], lw=6, alpha=0.4, label=LABEL[c])
ax.set_xlabel("minutes since start"); ax.set_ylabel("system power, W (PSTR)")
ax.set_title("Total system power over the whole run (shaded = measured windows)", loc="left", fontsize=11, fontweight="bold")
ax.legend(frameon=False, fontsize=8, ncol=3, loc="upper right")
fig.tight_layout(); fig.savefig(os.path.join(FIG, "timeline_system_power.png")); plt.close(fig)

# ---------- markdown summary ----------
with open(os.path.join(RUN, "summary.md"), "w") as f:
    f.write(f"# Summary: {os.path.basename(RUN)}\n\nMean ± SD across rounds (n). Unit of replication = one window.\n\n")
    for sc in sorted({r["scenario"] for r in rows}):
        f.write(f"## {sc}\n\n| Metric | " + " | ".join(LABEL[c] for c in ORDER) + " |\n|---|" + "---|" * len(ORDER) + "\n")
        for k in METRICS:
            cells = []
            for c in ORDER:
                s_ = get(sc, c, k)
                cells.append(f"{s_['mean']:.3g} ± {s_['sd']:.2g} (n={s_['n']})" if s_ else "—")
            if any(x != "—" for x in cells):
                f.write(f"| {k} | " + " | ".join(cells) + " |\n")
        f.write("\n")
print("wrote", os.path.join(RUN, "summary.md"), "and", len(os.listdir(FIG)), "figures")
