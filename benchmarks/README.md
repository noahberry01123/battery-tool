# Benchmarks

A reproducible framework for testing Battery Tool's Extreme Low Power Mode against normal operation and
macOS Low Power Mode, plus the fan app (MacFanCtl / FanCurve). It replaces nothing in `bench/` (the earlier,
preliminary measurements) and never changes application code.

Results live in `results/<timestamp>-<label>/`, one folder per run, never overwritten. The validation report
is in `report/`.

## What is measured, and how

| Quantity | Source | Root? | Label used in results |
|---|---|---|---|
| Total system power | SMC `PSTR`, 1 s | no | `system_w` |
| Battery power (on battery only) | SMC `PPBR`, 1 s; ioreg cross-check | no | `battery_w` |
| CPU power, GPU power | `powermetrics` cpu_power / gpu_power | yes | `cpu_w`, `gpu_w` |
| P / E cluster busy %, frequency | `powermetrics` | yes | `p_active`, `e_active`, `p_mhz`, `e_mhz` |
| Share of CPU time on P-cores, per process and in total | `proc_pid_rusage(RUSAGE_INFO_V6)` `ri_user_ptime + ri_system_ptime` vs total CPU time | no | `pshare_all`, `pshare_demoted`, `pshare_other`, `procs_mostly_e/p` |
| CPU / GPU temperature | SMC `Tp*` (20 keys, hottest), `Tg05/Tg0D` | no | `cpu_c`, `gpu_c` |
| Battery temperature | SMC `TB0T` | no | `batt_c` |
| "Palm rest" sensors | SMC `Ts0P/Ts1P` (community-identified, unverified, whole degrees) | no | `palm0_c`, `palm1_c` |
| Fan speed | SMC `F<n>Ac` | no | `fan0_rpm` |
| Job time, job P-core share | the workload measures itself (`proc_pid_rusage` on exit) | no | `job_s`, `pshare` |
| Background responsiveness proxy | timer-wakeup latency of an eligible process (10 ms sleeps) | no | `lat_median_ms`, `lat_p95_ms` |

Not measurable here: chassis surface temperature (needs an IR thermometer; see report), ambient temperature,
per-core residency of an individual process over time (only cumulative P-core time per process is exposed).

## Scripts

| Script | What it does | Changes settings? |
|---|---|---|
| `build.sh` | builds the read-only collectors into `bin/` | no |
| `run.py` | conditions A Normal / B Low Power Mode / C Extreme, counterbalanced rounds, scenarios `idle`, `sustained` (8 jobs, 90 s), `single` (1 background job), `multi` (8 jobs + latency probe), `light` (fixed-work bursts for the battery test); keeps the display on; protects the collectors from demotion; `--helper DIR` reuses a running root helper | yes: Battery Tool mode, auto-trigger and protected list, `pmset lowpowermode` (via root helper), optional charge hold; all restored |
| `tools/roothelper.sh` | root side of `run.py`: only `pmset -a lowpowermode 0/1` and `powermetrics`; restores Low Power Mode on exit | yes (root) |
| `analyze.py` | per-window metrics, statistics across rounds, charts (`figures/`), `summary.md` | no |
| `fan_test.py` | fan app Auto vs Curve vs Manual 100% under the same heat load; overheat guard; restores the config | fan app config only |
| `fan_firmware_test.py` | fan daemon stopped (pure Apple firmware) vs the app's Auto mode, Low Power Mode forced off | fan daemon stop/start, `pmset` (root helper) |
| `reliability_test.py` | daemon `kill -9` and sleep/wake with process-policy checks against the change record | Battery Tool mode, daemon restart, sleep (root helper) |
| `battery_analyze.py` | battery-test summary: charge used per hour (ioreg), system power, estimated runtime | no |
| `frontmost_latency.py` | time from bringing a demoted app to the front until it is restored (Extreme mode on) | no (opens TextEdit) |

## Reproduce

```sh
cd benchmarks && ./build.sh
python3 run.py --dry --label smoke --conditions A --reps 1 --idle 10 --single-rounds 2000 --multi-rounds 500   # pipeline check, changes nothing
python3 run.py --label abc --reps 3 --hold-charge          # ~55 min on AC; one admin prompt
/opt/homebrew/bin/python3 analyze.py results/<run_id>
# battery test (unplugged, start >= 90%, stops at 20%):
caffeinate -di python3 run.py --label battery --require-battery --scenarios light --idle 1200 --settle 60 --cooldown 0 --reps 2
python3 fan_test.py --reps 2                               # ~36 min
python3 frontmost_latency.py 10                            # Extreme mode on
```

Rules the runner follows: the experimental unit is one measured window (never a telemetry sample); condition
order alternates ABC / CBA; every window has a settle period before it; failures go to `failures.jsonl`;
previous Battery Tool and Low Power Mode settings are restored at the end.
