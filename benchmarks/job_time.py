#!/opt/homebrew/bin/python3
"""Chart of the single background job's time: Normal and Low Power Mode as mean ± SD, Extreme as one bar per
round (its rounds vary 4x, so a mean would hide that). This is report/figures/bg_single_job_time.png.
Usage: job_time.py results/<run_id>/windows_metrics.csv out.png
"""
import csv, statistics as st, sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

CSV, OUT = sys.argv[1], sys.argv[2]
ORDER = ["normal", "lowpower", "extreme"]
LABEL = {"normal": "Normal", "lowpower": "Low Power Mode", "extreme": "Extreme LPM"}
COLOR = {"normal": "#8a8f98", "lowpower": "#5b7fa6", "extreme": "#1f6feb"}
NOTE = ("MacBookPro18,3 (M1 Pro 8P+2E), macOS 26.6.2, on AC with charging held, fans fixed at max.\n"
        "Normal, Low Power Mode: mean of 3 rounds, error bars = SD. Extreme: each round.")

t = {c: [] for c in ORDER}
for r in csv.DictReader(open(CSV)):
    if r["scenario"] == "bg_single" and r["job_s"]:
        t[r["condition"]].append(float(r["job_s"]))

plt.rcParams.update({"font.size": 10, "axes.spines.top": False, "axes.spines.right": False, "figure.dpi": 150})
fig, ax = plt.subplots(figsize=(6.4, 3.8))
W = 0.8
for i, c in enumerate(ORDER[:2]):
    m, sd = st.mean(t[c]), st.stdev(t[c])
    ax.bar(i, m, W, yerr=sd, capsize=4, color=COLOR[c])
    ax.annotate(f"{m:.1f} s", (i, m + sd), ha="center", va="bottom", xytext=(0, 4), textcoords="offset points", fontsize=8)
runs = sorted(t["extreme"])
w = W / len(runs)
for j, y in enumerate(runs):
    x = 2 - W / 2 + w * (j + 0.5)
    ax.bar(x, y, w * 0.9, color=COLOR["extreme"])
    ax.annotate(f"{y:.0f} s", (x, y), ha="center", va="bottom", xytext=(0, 4), textcoords="offset points", fontsize=8)
ax.set_xticks(range(3), [LABEL[c] for c in ORDER])
ax.set_ylabel("seconds"); ax.set_title("Time to finish one background job", loc="left", fontsize=11, fontweight="bold")
ax.set_ylim(0, max(runs) * 1.15)
fig.text(0.01, 0.01, NOTE, fontsize=6.5, color="#666")
fig.tight_layout(rect=(0, 0.07, 1, 1)); fig.savefig(OUT); plt.close(fig)
print({c: v for c, v in t.items()})
