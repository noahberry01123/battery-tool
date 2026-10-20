#!/opt/homebrew/bin/python3
"""Battery test analysis (run.py --require-battery --scenarios light): per condition, mean battery power (SMC PPBR),
energy per hour, charge used per window (ioreg mAh), and an ESTIMATED runtime from the battery's present full
capacity. Run analyze.py on the folder first. Usage: battery_analyze.py results/<run_id>-battery
"""
import csv, json, math, os, re, statistics as st, sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

RUN = sys.argv[1]
rows = [r for r in csv.DictReader(open(os.path.join(RUN, "windows_metrics.csv"))) if r["scenario"] == "light"]
meta = json.load(open(os.path.join(RUN, "meta.json")))
cap = int(re.search(r'"AppleRawMaxCapacity" = (\d+)', meta["battery"]).group(1))          # mAh, present full charge


def ioreg(w, tag, key):
    t = open(os.path.join(RUN, "battery", f"{w}_{tag}.txt")).read()
    m = re.search(rf'"{key}" = (\d+)', t)
    return int(m.group(1)) if m else None


ORDER = ["normal", "lowpower", "extreme"]; LABEL = {"normal": "Normal", "lowpower": "Low Power Mode", "extreme": "Extreme LPM"}
out = []
for r in rows:
    w = r["window"]; secs = float(r["seconds"])
    mah = (ioreg(w, "start", "AppleRawCurrentCapacity") or 0) - (ioreg(w, "end", "AppleRawCurrentCapacity") or 0)
    v = (ioreg(w, "start", "Voltage") or 0) / 1000
    out.append({"window": w, "condition": r["condition"], "rep": r["rep"], "minutes": secs / 60, "battery_w": float(r["battery_w"]),
                "system_w": float(r["system_w"]), "wh_per_h": float(r["battery_w"]), "mah_used": mah, "volts": v,
                "cpu_c": float(r["cpu_c"]) if r["cpu_c"] else None, "batt_c": float(r["batt_c"]) if r["batt_c"] else None})
with open(os.path.join(RUN, "battery_windows.csv"), "w", newline="") as f:
    wr = csv.DictWriter(f, fieldnames=list(out[0].keys())); wr.writeheader(); wr.writerows(out)

lines = ["| Condition | n | System power, SMC PSTR (W) | Battery power, SMC PPBR (W) | Charge used (mAh/h, ioreg) | Estimated runtime, full battery* | CPU temp (°C) | Battery temp (°C) |",
         "|---|---|---|---|---|---|---|---|"]
summ = {}
for c in ORDER:
    sel = [o for o in out if o["condition"] == c]
    if not sel:
        continue
    mah_h = [o["mah_used"] / (o["minutes"] / 60) for o in sel]; m = st.mean(mah_h); sd = st.stdev(mah_h) if len(mah_h) > 1 else 0
    sysw = [o["system_w"] for o in sel]; ppbr = [o["battery_w"] for o in sel]
    summ[c] = (m, sd, len(sel), st.mean(sysw), st.stdev(sysw) if len(sysw) > 1 else 0)
    lines.append(f"| {LABEL[c]} | {len(sel)} | {st.mean(sysw):.2f} ± {st.stdev(sysw) if len(sysw) > 1 else 0:.2f} | {st.mean(ppbr):.2f} | "
                 f"{m:.0f} ± {sd:.0f} | {cap / m:.1f} h | {st.mean(o['cpu_c'] for o in sel if o['cpu_c']):.1f} | {st.mean(o['batt_c'] for o in sel if o['batt_c']):.1f} |")
base = summ.get("normal", (None,))[0]; base_w = summ.get("normal", (None, None, None, None))[3]
rel = [f"{LABEL[c]}: {100 * (summ[c][0] - base) / base:+.0f}% charge, {100 * (summ[c][3] - base_w) / base_w:+.0f}% system power"
       for c in ORDER if c in summ and base and c != "normal"]
text = ("# Battery test summary\n\n" + "\n".join(lines) + f"\n\nRelative to Normal: {'; '.join(rel)}\n\n"
        f"*Estimate = present full capacity ({cap} mAh, ioreg AppleRawMaxCapacity) ÷ charge used per hour, for this light "
        "workload. Not a measured full discharge; the capacity figure of an aged cell (77% health) is itself an estimate. "
        "SMC PPBR reads ~12% above both PSTR and the charge counter and is shown for reference only.\n")
open(os.path.join(RUN, "battery_summary.md"), "w").write(text)

fig, ax = plt.subplots(figsize=(6.4, 3.8))
cs = [c for c in ORDER if c in summ]
b = ax.bar([LABEL[c] for c in cs], [summ[c][0] for c in cs], yerr=[summ[c][1] for c in cs], capsize=4,
           color=["#8a8f98", "#5b7fa6", "#1f6feb"][:len(cs)])
for rect, c in zip(b, cs):
    ax.annotate(f"{summ[c][0]:.0f} mAh/h\n{summ[c][3]:.1f} W system\nn={summ[c][2]}", (rect.get_x() + rect.get_width() / 2, summ[c][0]), ha="center", va="bottom",
                xytext=(0, 4), textcoords="offset points", fontsize=8)
ax.set_ylabel("charge used per hour (mAh/h, ioreg)"); ax.spines["top"].set_visible(False); ax.spines["right"].set_visible(False)
ax.set_ylim(0, max(summ[c][0] + summ[c][1] for c in cs) * 1.35)
ax.set_title("Battery drain, light background load", loc="left", fontsize=11, fontweight="bold")
fig.text(0.01, 0.01, "MacBookPro18,3, on battery, same apps, 20-min windows, A B C C B A. Error bars = SD.", fontsize=6.5, color="#666")
fig.tight_layout(rect=(0, 0.04, 1, 1)); os.makedirs(os.path.join(RUN, "figures"), exist_ok=True)
fig.savefig(os.path.join(RUN, "figures", "battery_power.png"), dpi=150)
print(text)
