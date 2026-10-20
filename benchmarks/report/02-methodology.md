# Methodology, limitations and manual procedures

## Configurations

| Code | Name | What is set |
|---|---|---|
| A | Normal | Battery Tool Extreme mode off; `pmset -a lowpowermode 0` |
| B | Low Power Mode | Extreme mode off; `pmset -a lowpowermode 1` (Apple's built-in setting) |
| C | Extreme LPM | Low Power Mode on (set by Battery Tool) + every eligible user process demoted with `taskpolicy -b` (~300–360 processes here) |
| D, E | Fan app only / Extreme + fan app | not run as separate power conditions: the fan app was held at Manual 100% for every A/B/C run, and compared on its own in the fan test |

Battery Tool's auto-trigger was off during runs and restored afterwards. On AC, the battery charge was held at its
current level (Battery Tool charge limit set to the current %), so charging added no heat or power; restored to 80/75%.

## Scenarios

| Scenario | Workload | Fixed | Representative of |
|---|---|---|---|
| `idle` | the user's normally open apps (about 115–130 apps listed by `lsappinfo`: a browser, a code editor, chat apps), no added load, 120 s | duration | an idle desktop with background apps; activity varies with what those apps do |
| `sustained8` | 8 processes hashing continuously, 90 s | duration | sustained background compute (a build, an export) |
| `bg_single` | 1 process, 46,000 × SHA-256 of 1 MiB | work | one background CPU task |
| `bg_multi` | 8 processes × 12,000 rounds + a 10 ms timer-latency probe | work | parallel background work; probe = responsiveness of a demotable process |
| `light` (battery test) | 0.3 s of hashing every 10 s | duration | the duty cycle of light interactive use; not a model of a specific app |

Not automated, by design (they need the network, user files, or a person): web browsing, video playback, code editing,
real compilation, application switching by hand. The idle scenario includes whatever the open apps were doing.

## Measurement and statistics

- **Unit of replication = one window** (condition × scenario × round). Telemetry samples within a window are averaged,
  never treated as independent repetitions.
- 3 rounds per condition, order counterbalanced A B C / C B A / A B C, 30 s settle after each switch, 30 s cool-down
  between windows.
- Reported: mean ± SD (n), median, min, max; 95% CI (t-distribution) only where n ≥ 3 and stated as such.
- **Power labels:** `system_w` = SMC `PSTR` (whole computer, from the adapter on AC); `cpu_w`, `gpu_w` = powermetrics
  estimates for the CPU and GPU only. CPU power is never presented as computer power.
- **Core split:** cumulative CPU time on P-cores per process (`ri_user_ptime + ri_system_ptime`) vs total, differenced
  between the start and end of each window. Processes that start and end inside a window are missed by the snapshots;
  the workloads therefore report their own split on exit.
- **Energy per task:** whole-system energy = integral of `PSTR` over the job's duration (includes the idle cost of the
  rest of the computer, which is the real cost of waiting longer). The OS's per-process energy estimate
  (`ri_energy_nj`) is reported separately and labelled as an estimate.

## Limitations

- **One machine, one battery** (77% health, Service Recommended). Results describe this MacBook, not M1 Pro Macs in general.
- **Real background activity** varies between windows; the user's apps were left running on purpose (that is the use
  case), which adds variance. Thermal drift is reduced by counterbalancing, not eliminated.
- **Fans fixed at maximum** in the power runs: temperatures are lower than with Apple's fan control, and differences
  between modes are smaller than they would be with automatic fans.
- **Short windows:** powermetrics needs ≥ 1 s per sample and starts with a delay; windows under ~5 s have few or no
  powermetrics samples (system power from the SMC is still recorded).
- **SMC key meanings** (`PSTR`, `PPBR`, `Ts0P/Ts1P`) come from community documentation, not Apple. `PSTR` was checked
  against battery `Voltage × Amperage` on battery (see results); `Ts0P/Ts1P` are reported but not relied on.
- **Per-process P/E residency over time** is not available; only cumulative P-core time. That is enough to say what share
  of a process's CPU time ran on P-cores, not exactly when.
- **The runner itself** (Python) and the collectors are eligible processes, so under Extreme they are demoted too; their
  CPU use is small (collector overhead below).

## Manual procedure: chassis (skin) temperature

CPU temperature is not skin temperature. To measure what you feel, use an IR thermometer or thermal camera:

1. Same room, note the ambient temperature; lid open, same brightness; let the Mac idle 10 min.
2. Put a small piece of matte tape (emissivity ≈ 0.95) on each spot, so readings of the aluminium are valid:
   left palm rest, right palm rest, keyboard centre (between G and H), above the keyboard (centre), bottom case centre.
3. Run one configuration for 15 min with the same workload; measure each spot 3 times at 13–15 min; average.
4. Repeat for A, B, C in the order A B C C B A. Record in `report/chassis-template.csv`.

## Battery-life protocol (prepared, not yet run)

- Charge to ≥ 90%, unplug, same brightness, volume, Wi-Fi, open apps; note ambient temperature.
- `python3 run.py --label battery --require-battery --scenarios light --idle 1200 --settle 60 --cooldown 0 --reps 2`
  runs A B C C B A, 20 min each (~2 h), and **stops at 20%** (never deep-discharges).
- Analysis: mean battery power (SMC `PPBR`) per condition, energy per hour (Wh/h), and *estimated* runtime =
  nominal capacity (from ioreg, mAh × voltage) ÷ mean power, labelled as an estimate. Battery % alone is not used.
