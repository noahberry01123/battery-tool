#!/opt/homebrew/bin/python3
"""Analyse a fan_test.py run: per mode and round, load-phase steady-state CPU temperature, fan RPM,
system power, time to reach steady state, and cool-down time. Charts into <run>/figures.
Usage: fan_analyze.py results/<run_id>-fans
"""
import csv, os, statistics as st, sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

RUN = sys.argv[1]; FIG = os.path.join(RUN, "figures"); os.makedirs(FIG, exist_ok=True)
tel = []
for r in csv.DictReader(open(os.path.join(RUN, "telemetry.csv"))):
    try:
        tel.append({k: float(v) if v else None for k, v in r.items()})
    except ValueError:
        pass
win = list(csv.DictReader(open(os.path.join(RUN, "fan_windows.csv"))))
COLOR = {"auto": "#8a8f98", "curve": "#5b7fa6", "manual100": "#1f6feb", "firmware": "#444b55", "app_auto": "#b45309"}
LABEL = {"auto": "Apple automatic", "curve": "Curve 55→90 °C", "manual100": "Manual 100%",
         "firmware": "Fan daemon stopped (Apple firmware)", "app_auto": "Fan app Auto (re-asserts auto every 2 s)"}


def seg(a, b):
    return [r for r in tel if a <= r["epoch"] <= b]


rows = []
for w in win:
    if w["phase"] == "settle":
        continue
    a, b = float(w["start"]), float(w["end"]); t = seg(a, b)
    temps = [(r["epoch"] - a, r["cpu_max_c"]) for r in t if r["cpu_max_c"]]
    if not temps:
        continue
    m = {"mode": w["mode"], "rep": int(w["rep"]), "phase": w["phase"], "aborted": w["aborted"]}
    last60 = [v for s, v in temps if s >= (b - a) - 60]
    m["temp_last60_c"] = st.mean(last60) if last60 else None
    m["temp_peak_c"] = max(v for _, v in temps)
    m["fan0_rpm"] = st.mean([r["fan0_rpm"] for r in t if r["fan0_rpm"]] or [0])
    m["system_w"] = st.mean([r["system_w"] for r in t if r["system_w"]] or [0])
    if w["phase"] == "load" and m["temp_last60_c"]:
        target = m["temp_last60_c"] - 1.0                      # time to get within 1 C of the final level
        m["t_steady_s"] = next((s for s, v in temps if v >= target), None)
    if w["phase"] == "cool":
        start_t = temps[0][1]; floor = min(v for _, v in temps)
        half = start_t - (start_t - floor) / 2
        m["t_half_cool_s"] = next((s for s, v in temps if v <= half), None)
    rows.append(m)

with open(os.path.join(RUN, "fan_metrics.csv"), "w", newline="") as f:
    keys = sorted({k for r in rows for k in r}); w_ = csv.DictWriter(f, fieldnames=keys); w_.writeheader(); w_.writerows(rows)

lines = ["| Mode | Phase | n | CPU temp, last 60 s (°C) | Peak (°C) | Fan 0 (rpm) | System power (W) | Time to steady / half-cool (s) |",
         "|---|---|---|---|---|---|---|---|"]
for mode in LABEL:
    for ph in ("load", "cool"):
        sel = [r for r in rows if r["mode"] == mode and r["phase"] == ph]
        if not sel:
            continue
        f = lambda k: st.mean([r[k] for r in sel if r.get(k) is not None]) if any(r.get(k) is not None for r in sel) else float("nan")
        sd = lambda k: st.stdev([r[k] for r in sel if r.get(k) is not None]) if sum(r.get(k) is not None for r in sel) > 1 else 0
        tk = "t_steady_s" if ph == "load" else "t_half_cool_s"
        lines.append(f"| {LABEL[mode]} | {ph} | {len(sel)} | {f('temp_last60_c'):.1f} ± {sd('temp_last60_c'):.1f} | {f('temp_peak_c'):.1f} | "
                     f"{f('fan0_rpm'):.0f} | {f('system_w'):.1f} | {f(tk):.0f} |")
open(os.path.join(RUN, "fan_summary.md"), "w").write("# Fan test summary\n\n" + "\n".join(lines) + "\n\nAborted windows: "
                                                     + (", ".join(f"{r['mode']} r{r['rep']}" for r in rows if r["aborted"]) or "none") + "\n")

# temperature and fan speed over load + cool, one line per mode (round 1)
fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(8, 5.5), sharex=True)
for mode in LABEL:
    ws = [w for w in win if w["mode"] == mode and w["rep"] == "1" and w["phase"] in ("load", "cool")]
    if not ws:
        continue
    a = float(ws[0]["start"]); b = float(ws[-1]["end"]); t = seg(a, b)
    ax1.plot([r["epoch"] - a for r in t if r["cpu_max_c"]], [r["cpu_max_c"] for r in t if r["cpu_max_c"]], color=COLOR[mode], label=LABEL[mode], lw=1.2)
    ax2.plot([r["epoch"] - a for r in t if r["fan0_rpm"]], [r["fan0_rpm"] for r in t if r["fan0_rpm"]], color=COLOR[mode], lw=1.2)
    load_len = float(ws[0]["end"]) - a
ax1.axvline(load_len, color="#999", ls="--", lw=0.8); ax2.axvline(load_len, color="#999", ls="--", lw=0.8)
ax1.text(load_len + 3, ax1.get_ylim()[1] - 3, "load stops", fontsize=8, color="#666", va="top")
ax1.set_ylabel("hottest CPU sensor (°C)"); ax2.set_ylabel("fan 0 (rpm)"); ax2.set_xlabel("seconds since the 8-process load started")
ax1.set_title("Fan modes under the same load (round 1)", loc="left", fontsize=11, fontweight="bold"); ax1.legend(frameon=False, fontsize=8)
for ax in (ax1, ax2):
    ax.spines["top"].set_visible(False); ax.spines["right"].set_visible(False)
fig.text(0.01, 0.005, "MacBookPro18,3, Extreme LPM off, on AC with charging held; installed MacFanCtl daemon; 1 s SMC samples.", fontsize=6.5, color="#666")
fig.tight_layout(rect=(0, 0.03, 1, 1)); fig.savefig(os.path.join(FIG, "fan_modes_timeseries.png"), dpi=150); plt.close(fig)
print(open(os.path.join(RUN, "fan_summary.md")).read())
