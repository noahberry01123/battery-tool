# Measurements

How the numbers in the README and the article were measured, and the raw data.
Machine: 14-inch MacBook Pro, M1 Pro (8 performance + 2 efficiency cores), 32 GB, macOS 26.6.2.
Both fans were fixed at maximum ([MacFanCtl]({{MACFANCTL_REPO_URL}}), Manual 100%) for every run.

## Results

### Same apps open: off vs macOS Low Power Mode vs Extreme LPM (17 Oct 2026)

Chrome playing music, VS Code and chat open. Off → Low Power Mode only → Extreme, repeated twice,
170 s measured per window; values are the average of the two rounds.

| | Off | Low Power Mode only | Extreme LPM (Low Power Mode + ~300 processes on background QoS) |
|---|---|---|---|
| CPU power | 3.6 W | 2.3 W (−35%) | 0.7 W (−81% vs off, −70% vs Low Power Mode) |
| Hottest CPU sensor, average | 61.4 °C | 57.9 °C | 52.7 °C |
| Hottest CPU sensor, peak | 67.2 °C | 60.9 °C | 58.9 °C |
| P0 performance cluster busy | 76% | 79% | 25% |
| P0 cluster active frequency | 3,153 MHz | 2,448 MHz | 1,126–1,673 MHz |
| Efficiency cluster busy | 48% | 52% | 100% |

An earlier off → Extreme → off run on 16 Oct gave the same picture: 2.6 W → 0.8 W (−70%), hottest
sensor 61.3 → 53.4 °C. The "off" level differs between days because background activity differs.

### Fixed workload (SHA-256 over 1 MiB, `work.py`), Extreme LPM itself off

| | Normal | Low Power Mode only | `taskpolicy -b` (what Extreme does to background apps) |
|---|---|---|---|
| 1 process, 46,000 rounds | 20.3 s | 26.0 s (1.3×) | 70.5 s (3.5×) |
| 8 processes, 12,000 rounds each | 6.0 s | 7.3 s (1.2×) | 76.3 s (12.7×) |

### What this says, honestly

- **Plain Low Power Mode already gets about 44% of the saving** (1.3 of the 2.9 W), and costs heavy
  work only 1.2–1.3×. It caps the performance cores at 2,448 MHz, but they stay just as busy.
- **Extreme LPM adds the rest** by emptying the performance cores (busy 79% → 25%): another 1.6 W
  and 5 °C below plain Low Power Mode.
- **The price is background speed.** Heavy work in a background app runs 3.5–12.7× slower and uses
  more total energy because it runs longer. The frontmost app is not affected.
- If you often run heavy work in the background, plain Low Power Mode is the better trade.
- Single machine, short runs, fans fixed at maximum, normal background activity: indicative, not a
  lab benchmark. The normal and `taskpolicy -b` timings were taken on 16 Oct, the Low Power Mode
  timings on 17 Oct.
- The comparison windows were rebuilt from the battery-tool log timestamps of each mode change
  (the first script run failed to record them), trimmed 5 s at each end: `results-2026-10-17-lpm-comparison/windows.txt`.

Raw data: `results-2026-10-16/` (synthetic + off/on/off) and `results-2026-10-17-lpm-comparison/`.

## Run it yourself

```sh
sudo powermetrics -i 1000 -n 2400 --samplers cpu_power,thermal -o bench/pm.txt &   # ~40 min
MACFANCTL=/path/to/macfanctl bench/temps.sh > bench/temps.txt &
battery-tool lowpower auto off && battery-tool lowpower off
bench/synthetic.sh      # ~11 min: phases.txt
bench/realworld.sh      # ~10 min: toggles the mode off/on/off, realworld.txt
sudo bench/compare.sh $USER   # ~21 min: off / Low Power Mode / Extreme, twice; compare.txt + pm2.txt
python3 bench/analyze.py bench               # synthetic summary
python3 bench/analyze.py bench realworld.txt # same-apps summary
python3 bench/analyze.py bench compare.txt 2 # comparison (needs temps2.txt from temps.sh)
```

| File | What it does |
|---|---|
| `work.py` | Fixed CPU workload; prints wall seconds |
| `synthetic.sh` | 1 and 8 processes, normal vs `taskpolicy -b`, 60 s cool-down before each |
| `realworld.sh` | Extreme Low Power Mode off / on / off, 20 s settle + 180 s measured each |
| `compare.sh` | Off / plain Low Power Mode / Extreme LPM, alternated twice (root) |
| `temps.sh` | Hottest `Tp*` SMC sensor once a second (via the MacFanCtl CLI) |
| `analyze.py` | Averages powermetrics + temperatures over each phase window |

> **Superseded:** these were preliminary measurements. The validated benchmark, with repeated and counterbalanced runs, is in [`../benchmarks/`](../benchmarks/report/README.md).
