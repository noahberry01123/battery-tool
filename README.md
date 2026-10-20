# Battery Tool

A small, free DIY battery manager for Apple Silicon MacBooks. It is a Swift CLI, a root launchd daemon and a menu bar app, with no third-party dependencies. It was built and tested on an M1 Pro MacBook Pro (MacBookPro18,3) running macOS 26.6.2.

I built it to answer a question: my M1 Pro gets warmer than I'd like during casual work, so what happens if most everyday apps run on the two efficiency cores instead of the eight performance cores? The full story and measurements: [Running My M1 Pro on Its Efficiency Cores]({{MEDIUM_ARTICLE_URL}}). Its sister project, [Fan Curve]({{FANCURVE_REPO_URL}}), is a free fan controller I use alongside it.

- **Charge limit**: stops charging at 80% and resumes at or below 75% (configurable).
- **Heat guard**: pauses charging when the battery reaches 35 °C and resumes at or below 32 °C (configurable; it always resumes 3 °C lower).
- **Duty cycle** (optional, off by default): at or above a "warm" temperature it alternates charging on and off (default 30 s on / 60 s off) to approximate slower charging.
- **Extreme Low Power Mode** (optional, off by default): macOS Low Power Mode, plus your apps moved to background QoS so their work runs on the efficiency cores. It can switch on automatically at 40 °C and off again at 37 °C or lower.

> **Extreme Low Power Mode is an approximation.** macOS does not allow disabling the performance cores on Apple Silicon. Battery Tool runs your apps at background QoS (`taskpolicy -b`), which keeps their work on the efficiency cores, and turns on macOS Low Power Mode. System processes, protected apps and the frontmost app keep full speed and can still use the P-cores.

## Measured results

Validated on my M1 Pro (3 modes × 3 rounds, alternating, same apps open, display on, fans fixed at maximum, on AC with charging held; repeated after fixing flaws in a first attempt). Full report, method, flaws found, scripts and raw data: [benchmarks/report](benchmarks/report/README.md).

| Mean of 3 rounds | Normal | macOS Low Power Mode | Extreme LPM |
|---|---|---|---|
| Background job: share of its CPU time on performance cores | 100% | 100% | 0% |
| Idle with apps open: whole-system power | 10.5 W | 9.6 W (−8%) | 7.7 W (−27%) |
| 8 background jobs: whole-system power | 28.6 W | 20.9 W (−27%) | 7.5 W (−74%) |
| 8 background jobs: hottest CPU sensor | 73.8 °C | 64.1 °C | 48.1 °C |
| One background job of fixed work: time | 19.7 s | 25.7 s (1.3×) | 1.5–5 min (4–16×); 7–33 min in a busier first run |
| ...whole-system energy to finish it | 272 J | 294 J | 680–2,600 J (2.5–10×); 20–50× in the first run |

- Demoted processes really run on the efficiency cores, and under background load power and temperature drop a lot.
- The saving comes from doing background work more slowly: the demoted processes (235–350 here) share two efficiency cores, so background jobs take 4–100× longer and cost more total energy. Use Extreme for light sessions, not while waiting on background work; plain Low Power Mode costs heavy work only 1.2–1.3×.
- A demoted app brought to the front took 3–31 s (median 11 s) to get full speed back.
- Recovery was tested: after `kill -9` the daemon was back in 1.2 s, restored all 302 processes from its change record and re-applied the mode; state was consistent after sleep/wake; switching off left nothing demoted.
- On battery with a light fixed-work background load, Extreme used 32% less charge per hour than Normal (449 vs 662 mAh/h; Low Power Mode −9%; 2 rounds per mode, display on). Chassis temperature has not been measured. The earlier numbers in [bench/](bench/README.md) were preliminary.

## Install

You need Xcode or the Command Line Tools (`xcode-select --install`).

```sh
git clone {{BATTERY_TOOL_REPO_URL}} battery-tool
cd battery-tool
./build.sh          # builds into build/ and runs the built-in self-test; no sudo
sudo ./install.sh   # installs, starts the daemon and the menu bar app
battery-tool status
```

`install.sh` keeps an existing config, so you can re-run it to upgrade.

## Commands

| Command | What it does |
|---|---|
| `battery-tool status` | Battery %, temperature, charging state and why, SMC key, settings, Low Power Mode, daemon. |
| `battery-tool set-limit <max> [<resume>]` | Charge limit, e.g. `set-limit 80 75`. Resume defaults to max − 5; `set-limit 100` means no limit. |
| `battery-tool set-temp <limit>` | Heat guard limit in °C (25–60). Charging resumes 3 °C lower. |
| `battery-tool enable` / `disable` | Turn charge management (limit, heat guard, duty cycle) on or off. When it's off, charging is always allowed. |
| `battery-tool pause` / `resume` | Suspend **everything**, restoring normal charging, Low Power Mode and process priorities, without uninstalling. Stays paused until you `resume`. |
| `battery-tool lowpower on` / `off` / `status` | Extreme Low Power Mode. |
| `battery-tool lowpower auto on` / `off [<temp>]` | Auto-trigger: on at ≥ temp (default 40 °C), off at ≤ temp − 3 °C. |
| `battery-tool duty-cycle on` / `off [--warm C] [--on S] [--off S]` | Duty-cycle charging when the battery is at least C °C (default 32 °C; 30 s on / 60 s off). |
| `battery-tool probe` | Re-verify the SMC charging key. The charger must be connected and the battery charging. |
| `battery-tool uninstall [--yes]` | Restore everything and remove Battery Tool. Asks for confirmation and your admin password. |

Settings take effect within about 5 s. The CLI waits for the daemon to apply them and prints the result. Changing settings needs an admin account but not `sudo`, because the config file is writable by the admin group.

## Menu bar

The menu bar shows battery %, temperature, a ⏸ when paused and an `E` when Extreme Low Power Mode is active. The menu has:

- charging state and reason, and Low Power Mode state
- an **Extreme Low Power Mode** on/off switch. One click turns it on or off; the line under it shows the live state, e.g. "On · 243 processes on efficiency cores"
- **Pause / Resume Battery Tool**
- **Settings…** (⌘,)
- **About Extreme Low Power Mode…** and **Open Log**
- **Uninstall and Restore Normal Charging…**

### Settings window

**Settings…** opens a window with every setting: charge management on/off, charge limit, heat guard, duty cycle, Extreme Low Power Mode (switch, auto-trigger), protected apps (type a name or pick from **Running Apps**), and the check/scan intervals.

- Changes take effect when you press **Apply**. **Revert** discards them; **Restore Defaults** fills in the defaults, which you then apply.
- The Extreme Low Power Mode switch at the top of its section acts immediately, like the one in the menu.
- Applying never undoes a pause or the Extreme Low Power Mode switch, even if you changed those from the menu or CLI while the window was open.
- It needs an admin account, like the CLI. No password is asked.

## How charging is controlled

The daemon writes the SMC charging-inhibit key. It finds the right key by probing rather than assuming:

1. At startup it checks which candidate keys exist and have the expected size: `CHTE` (newer macOS: `01000000` = inhibit, `00000000` = allow), then `CH0B` + `CH0C` (older macOS: `02` / `00`). On this M1 Pro with macOS 26.6.2, `CHTE` is the key; `CH0B`/`CH0C` don't exist.
2. The first time it pauses charging while the battery is actually charging, it verifies the effect: within 120 s, `ioreg -rn AppleSmartBattery` must report `IsCharging = No` and `pmset -g batt` must say "not charging". ioreg only refreshes every 30–60 s, which is why the window is that long. The real-time battery current (SMC `B0AC`) is logged as the fast signal.
3. The result is stored per macOS build in `state.json`, so a macOS update triggers a fresh verification.
4. If the key doesn't stop charging, the daemon re-enables charging, marks the key failed and falls back to the next candidate. If none is left it runs monitor-only and never blocks charging.
5. `battery-tool probe` runs the same check on demand: it pauses charging, confirms via ioreg/pmset, then re-enables charging and confirms it resumes.

The daemon reads battery %, temperature and charging state from `ioreg -rn AppleSmartBattery` (Temperature is in hundredths of °C) and `pmset -g batt` every 5 s.

## Extreme Low Power Mode details

- Turns on Low Power Mode with `pmset -b lowpowermode 1`. It also uses `pmset -c`, because `-b` alone has no effect while on the charger, which is exactly when heat builds up. The previous value of each is recorded first.
- Every 5 s it scans your processes and applies `taskpolicy -b -p <pid>` to each eligible one, so newly launched apps are caught too.
- **Never touched:**
  - processes of root, system accounts and other users
  - anything under `/System/Library`, `/usr/libexec`, `/usr/sbin`, `/sbin`, `/Library/Apple`
  - `WindowServer`, `loginwindow`, `kernel_task`, `launchd`
  - Battery Tool itself
  - the protected list, which is configurable
- The protected list defaults to Finder, Dock, Terminal and `@frontmost` (the frontmost app). Names match the process name, the executable name or any enclosing `.app` bundle. For example, `Terminal` protects everything inside `Terminal.app`, but not the shells you run in it.
- An app that becomes frontmost is restored to normal priority right away.
- Child processes inherit background QoS from a throttled parent. They are recorded and restored as well, including children that were reparented to launchd (e.g. a `tmux` server started from a throttled shell). Processes that were already in the background before the mode was turned on are left alone.
- Every change is written to the change record **before** it is made (`/usr/local/var/battery-tool/changes.tsv`): the original Low Power Mode values, and each process's pid, start time, original priority and nice value. Turning the mode off, pausing, stopping the daemon, a crash followed by restart, or uninstalling all undo every recorded change.
- **Audio protection** (`audio_safe_mode`, on by default): the process that is playing audio right now is never demoted, and is restored if it already was. Battery Tool asks CoreAudio which processes are outputting audio (macOS 14.2 or later), so no app names are involved. Protection lasts `audio_grace_seconds` (default 10) after the audio stops. `audio_protect_scope` sets what is protected: `"pid_active"` (default: the playing process plus the processes in the same `.app` using at least 2 % CPU while it plays — for Chrome the audible tab's renderer and the GPU process, not idle tabs; this keeps background audio clean), `"pid"` (only the playing process; can stutter when the app is in the background), `"pid_tree"` (plus its direct parent and children) or `"bundle"` (every process in the same `.app`). If the detection fails, everything already demoted is restored and nothing new is demoted until it works again. Every protect and release is logged with the PID, name, command line, scope and reason. `battery-tool lowpower status` shows what is protected.
- Real-time apps that don't go through CoreAudio output (rare) can still be added to `lowpower.protected`.

## Safety

- **Charging is always re-enabled when the daemon stops**:
  - **SIGTERM, SIGINT, SIGHUP**: the charge-inhibit keys are reset at once from a dedicated signal queue, and no further inhibit write is allowed. Then everything is restored.
  - **Crash** (SIGSEGV, Swift traps, and so on): a crash handler replays prepared "charging enabled" writes.
  - **SIGKILL**: launchd restarts the daemon (KeepAlive). Its first step is to write "charging enabled" to every charge-inhibit key, then it undoes any recorded Low Power Mode and process changes.
- **Unreadable or implausible battery data** means charging is allowed.
- **Unreadable `config.json` at daemon start**: the daemon acts as paused (charging allowed, nothing changed) until the file is fixed. A later bad edit keeps the last good config.
- **Restarts**: charge-limit and heat holds are saved in `policy.json`, so a restart inside a hold still waits for the resume point. Tightening a limit keeps a running hold; raising a limit re-evaluates at once.
- **Sleep**: a duty-cycle "off" phase never lasts through sleep. Charge-limit and heat holds do stay in place while asleep.
- **Monitor-only**: without a working key, Battery Tool never blocks charging.

## Uninstall

There are four independent ways:

1. Menu bar → **Uninstall and Restore Normal Charging…**: asks you to confirm, then shows the macOS admin password prompt.
2. `battery-tool uninstall`
3. `sudo /usr/local/lib/battery-tool/uninstall.sh`, or `sudo ./uninstall.sh` from this folder. The script is standalone: it needs neither the daemon nor the `battery-tool` binary, and carries its own small SMC helper. It compiles that helper if the installed copy is missing.
4. Create a file named `UNINSTALL-BATTERY-TOOL` on your Desktop. The daemon notices it within about 5 s, restores everything and runs the uninstaller. It leaves `BATTERY-TOOL-UNINSTALLED.txt` on your Desktop, or in `/Users/Shared` if macOS privacy settings block the Desktop, and shows a notification.

The uninstaller works through these steps:

1. Re-enables charging via SMC and verifies it by read-back, live current and pmset.
2. Restores Low Power Mode and process priorities from the change record.
3. Unloads the launchd jobs (`launchctl bootout`).
4. Deletes the plists, binary, config, state and logs.
5. Deletes the menu bar app.
6. Prints a confirmation.

It is safe to run repeatedly or on a half-installed system.

## Files

| Path | What |
|---|---|
| `/usr/local/bin/battery-tool` | CLI and daemon |
| `/usr/local/lib/battery-tool/` | `uninstall.sh`, `smc-helper`, install manifest |
| `/usr/local/etc/battery-tool/config.json` | configuration (JSON) |
| `/usr/local/var/battery-tool/` | `status.json`, `state.json` (key verification), `policy.json` (holds), `changes.tsv` (change record) |
| `/usr/local/var/battery-tool/log/battery-tool.log` | log, rotated at 1 MB, 5 files kept |
| `/Library/LaunchDaemons/local.battery-tool.daemon.plist` | daemon (root, starts at boot) |
| `/Library/LaunchAgents/local.battery-tool.menubar.plist` | menu bar app (at login) |
| `/Applications/BatteryTool.app` | menu bar app |

The log records every change with its reason: charging paused or resumed (and why), duty cycle started or stopped, Extreme Low Power Mode on or off (manual, auto-trigger with the temperature, pause, …), Low Power Mode changes with the originals, and process counts throttled or restored.

## Configuration

`/usr/local/etc/battery-tool/config.json` (defaults shown). Use the Settings window, the CLI, or edit the file directly. Out-of-range values are clamped.

```json
{
  "charge_limit": { "max_percent": 80, "resume_percent": 75 },
  "heat_guard": { "limit_c": 35 },
  "duty_cycle": { "enabled": false, "warm_c": 32, "on_seconds": 30, "off_seconds": 60 },
  "lowpower": {
    "enabled": false,
    "auto_trigger": { "enabled": false, "temp_c": 40 },
    "protected": ["Finder", "Dock", "Terminal", "@frontmost"],
    "scan_interval_seconds": 5,
    "audio_safe_mode": true,
    "audio_protect_scope": "pid_active",
    "audio_grace_seconds": 10
  },
  "enabled": true,
  "paused": false,
  "poll_interval_seconds": 5
}
```

## Troubleshooting

- **The Mac doesn't charge.** Run `battery-tool status`; it shows the live `CHTE` value and the reason. Run `battery-tool pause`, or force charging on with `sudo /usr/local/lib/battery-tool/smc-helper enable-charging`.
- **`sudo ./install.sh` says "Operation not permitted".** macOS privacy protection is blocking access to this folder (Documents, Desktop and Downloads are protected). Allow your terminal app under System Settings → Privacy & Security → Files and Folders (or Full Disk Access), or move the project folder elsewhere.
- **"daemon not running".** Check `sudo launchctl print system/local.battery-tool.daemon` and the log.
- macOS's own Optimized Battery Charging can also hold the charge at 80%. That is separate from Battery Tool.

## Credits and licensing

The SMC access code is original. It uses the public IOKit AppleSMC user-client interface and copies no code from other projects. Key names and values were cross-checked against public knowledge from the MIT-licensed [actuallymentor/battery](https://github.com/actuallymentor/battery) project. The GPL-2.0 `smc` tool from smcFanControl was not used.

## Related

- [Fan Curve]({{FANCURVE_REPO_URL}}) — free menu bar fan control for Apple Silicon (Auto / Manual / Curve), clamped to each fan's hardware limits.

## License

MIT — see [LICENSE](LICENSE). The software comes with no warranty and the author accepts no liability. Use at your own risk: Battery Tool writes the SMC charging key and changes process priorities. Every change is recorded and undone on uninstall, but it is a personal project, not affiliated with Apple.
