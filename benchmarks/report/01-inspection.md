# Phase 1 — Repository and system inspection

Read-only code audit of both repositories (19 Oct 2026). No application code was changed.
File:line references are to the repositories as of this date.

## Machine (measured)

| Item | Value | Source |
|---|---|---|
| Model | MacBookPro18,3 (14-inch, 2021) | `sysctl hw.model` |
| Chip | Apple M1 Pro, 8 performance + 2 efficiency cores | `sysctl hw.perflevel*` |
| Memory | 32 GB | `sysctl hw.memsize` |
| macOS | 26.6.2 (25G83) | `sw_vers` |
| Battery | 1,624 cycles, 77% maximum capacity, condition **Service Recommended**; design 6,075 mAh, nominal 4,662 mAh | `ioreg AppleSmartBattery`, `system_profiler SPPowerDataType` |
| Fans | 2; firmware min 1,200 rpm, max 5,779 / 6,241 rpm; both in **manual at maximum** (MacFanCtl) during inspection | SMC `F<n>Mn/Mx/Ac/Md` |

The battery's condition matters: runtime estimates from this battery do not transfer to a healthy one, and an aged cell's
capacity readings are noisier.

## Instrumentation available

| Measurement | Available? | How | Root? |
|---|---|---|---|
| Total system power | **Yes** | SMC `PSTR` (W), 1 s | no |
| Battery power | **Yes (on battery)** | SMC `PPBR` (W); cross-check ioreg `Voltage × InstantAmperage` (updates every 30–60 s) | no |
| CPU power, GPU power, ANE power | Yes | `powermetrics --samplers cpu_power,gpu_power` | yes |
| P/E cluster active residency and frequency | Yes | `powermetrics` cpu_power | yes |
| **Per-process CPU time on P-cores vs E-cores** | **Yes, for your own processes** | `proc_pid_rusage(RUSAGE_INFO_V6)`: `ri_user_ptime + ri_system_ptime` vs total. Root and other users' processes are not readable without root (silently skipped) | no |
| Per-process energy estimate | Yes (OS estimate) | `ri_energy_nj` | no |
| Per-process background-QoS time, darwin-bg flag | Yes | `ri_cpu_time_qos_background`; `PROC_FLAG_EXT_DARWINBG` | no |
| CPU / GPU die temperatures | Yes | SMC `Tp*` (20 keys), `Tg05`, `Tg0D` | no |
| Battery temperature | Yes | SMC `TB0T/TB1T/TB2T`; ioreg `Temperature` | no |
| Palm-rest area temperature | **Uncertain** | SMC `Ts0P`, `Ts1P` are *community-identified* as palm-rest sensors; Apple does not document them; they report whole degrees | no |
| External chassis temperature | **No** | needs an IR thermometer or thermal camera (manual procedure in the report) | — |
| Ambient temperature | **No** | no ambient sensor; record manually | — |
| Fan speed | Yes | SMC `F<n>Ac` | no |
| Performance counters (instructions, cycles) | Partly | `ri_instructions/ri_cycles/ri_pinstructions/ri_pcycles` per process; no system-wide PMC access without kperf | no |

## Battery Tool — how it works (verified in code)

- **Privileged part:** `battery-tool daemon`, root LaunchDaemon (KeepAlive). Menu app and CLI run as the user. IPC is files only:
  `config.json` (admin-writable, atomic rename), `status.json`, root-only `changes.tsv`, `state.json`, lock, log.
- **Extreme Low Power Mode:** on activation `pmset -b/-c lowpowermode 1` (originals recorded durably first). Every scan
  (default 5 s, only on daemon ticks) each eligible process gets `/usr/sbin/taskpolicy -b -p <pid>`; restore is `-B`.
  Identity is pid + start second; the darwin-bg state is read back with `proc_pidinfo` (`PROC_FLAG_EXT_DARWINBG`).
- **Eligible:** euid = console user, not pid ≤ 1 / self / exiting, not WindowServer, loginwindow, kernel_task, launchd,
  not under `/System/Library`, `/usr/libexec`, `/usr/sbin`, `/sbin`, `/Library/Apple`, not battery-tool itself.
- **Protected:** names in `lowpower.protected` (default Finder, Dock, Terminal, `@frontmost`), matched against process
  name, executable name and every enclosing `.app`. `@frontmost` = `launchctl asuser … lsappinfo front` + bundle path.
- **Audio protection:** CoreAudio process objects (`kAudioProcessPropertyIsRunningOutput`, macOS 14.2+); default scope
  `pid_active` = playing process + same-bundle processes using ≥ 2% of a core; 10 s grace; detection failure restores
  everything and demotes nothing.
- **Restoration:** write-ahead `changes.tsv`; restore on off / pause / auto-release / SIGTERM / daemon start / uninstall
  (`uninstall.sh`, run twice). Inherited darwin-bg children and orphans started after activation are recorded and restored.
- **Charging:** SMC `CHTE` (or `CH0B`/`CH0C`), verified by ioreg + pmset; crash and SIGTERM paths re-enable charging.
- **Temperature input:** battery temperature from ioreg only (30–60 s refresh). No CPU sensor is used by the app.
- **Tests:** `battery-tool selftest`, ~236 pure-logic checks. Not covered: `scan()`, restore paths, `taskpolicy` calls,
  daemon lifecycle (sleep, signals, reload), install/uninstall scripts.

## FanCurve — how it works (verified in code)

- Root daemon `fancurved` (2 s tick) reads `/Library/Application Support/FanCurve/config` (user-owned) and writes only
  SMC `F<n>Md` (mode) and `F<n>Tg` (target). Curve = linear between `low` and `high` on the hottest of 22 `Tp*/Tg*` keys,
  applied within each fan's `F<n>Mn..Mx`. Releases fans to firmware before sleep and when the lid is closed and unused;
  re-engages above 85 °C. SIGTERM returns fans to auto.
- **Installed on this Mac is the earlier build, MacFanCtl (`macfanctld`)**, not the renamed FanCurve code. Fan tests
  here test that build.
- No tests or benchmarks exist.

## Discrepancies and potential problems

Severity: **H** can affect correctness or safety, **M** behaviour differs from documentation, **L** cosmetic/minor.

### Battery Tool
| # | Sev | Finding | Where |
|---|---|---|---|
| 1 | H | **PID reuse (TOCTOU):** `taskpolicy` runs before the identity check; a pid reused between the scan's process list and the call puts an unrelated process (possibly another user's) into darwin-bg, which is then dropped from the record and never restored | ProcessScanner.swift:167-168, LowPower.swift:277-288 |
| 2 | M | If `lsappinfo` fails, an already-demoted frontmost app stays demoted (nothing new is demoted, but nothing protects it) | LowPower.swift:201-204 |
| 3 | M | Frontmost protection covers the app's pid and bundle only: its child processes outside the bundle (shells, compilers, language servers) are demoted | ProcessScanner.swift:83-95 |
| 4 | M | A newly frontmost app is restored at the next scan (~5 s default, up to ~60 s), not "right away" | README:100 vs LowPower.swift:38,55 |
| 5 | M | Background processes started after activation (orphans, children deliberately run with `taskpolicy -b`) are claimed and forced to normal on restore, contrary to "already-background processes are left alone" | LowPower.swift:177-194, 445-448 |
| 6 | M | On macOS < 14.2 the audio fail-safe is permanent, so Extreme mode demotes nothing; minimum system version is 13.0 | AudioProtect.swift:36-56 |
| 7 | M | Low Power Mode is applied only at activation; if changed externally while active, Extreme mode continues without it | LowPower.swift:113-147 |
| 8 | M | Auto-trigger uses battery temperature (ioreg, 30–60 s refresh), not CPU temperature; README does not say so | Battery.swift:49, Policy.swift:163-174 |
| 9 | M | The published "3.5–12.7× slower" was measured with `taskpolicy -b` alone, Low Power Mode off, on a different day from the Low Power Mode timings | bench/README.md |
| 10 | L | Setuid children (e.g. `/bin/ps`) of demoted shells are "restored" on every scan | live log |
| 11 | L | Every daemon restart restores all ~300 processes, then re-demotes them | LowPower.swift:81-88 |
| 12 | L | `realworld.sh` never recorded the process count (grep matches the disclaimer text) | bench/realworld.sh:7 |
| 13 | L | Settings window lacks the audio settings; status shows "on hold" when no SMC key exists | SettingsWindow.swift, Daemon.swift:460 |

### FanCurve
| # | Sev | Finding | Where |
|---|---|---|---|
| 1 | H | If `F<n>Mn/Mx` reads fail but `Tg` is writable, target becomes **0 rpm** (the `FanInfo` failure check is dead code) | fanapi.c:56-61, 86-89 |
| 2 | H | NaN `percent`/`low` passes the clamp and is written as the fan target | fanapi.c:87-88, fancurved.c:75 |
| 3 | H | Config is user-owned and opened with plain `fopen`: replacing it with a FIFO or `/dev/zero` symlink hangs the root daemon (no sleep release, SIGTERM not serviced; fans stay manual) | fanapi.c:106-115 |
| 4 | M | Curve with low ≥ high (reachable in the GUI) or unreadable sensors pins fans at minimum in manual | fancurved.c:75 |
| 5 | M | Two root controllers can fight if `make daemon` (CLI curve plist) and install.sh are both used; uninstall leaves the CLI plist | Makefile, uninstall.sh |
| 6 | M | Non-atomic config writes can make the daemon release the fans for one tick | fanapi.c:121-126 |
| 7 | M | GUI uses a macOS 15 API; README says macOS 13+ | FanCurve.swift:126 |
| 8 | L | SIGKILL or a crash leaves fans latched at the last manual target until KeepAlive restarts the daemon | fancurved.c:193-238 |

These are reported, not fixed: the brief was to validate, not to change the applications.
