# Article review: claims vs implementation and evidence

Article: `m1-pro-article/article.md` as of 17 Oct 2026. Evidence: `README.md` (this folder) and the code audit.

## Fully supported
- Extreme Low Power Mode turns on macOS Low Power Mode (battery and AC) and runs `taskpolicy -b` on eligible user processes every ~5 s. (code)
- Demoted processes run on the efficiency cores: measured 0.0% P-core share for the test job and 99.9–100% E-core share for demoted processes.
- Low Power Mode caps the P-cores at 2,448 MHz and they stay busy; Extreme mostly empties them. (powermetrics, both runs)
- Heavy background work gets much slower and can cost more total energy. (now measured directly: ~30× the whole-system energy)
- Plain Low Power Mode costs heavy work only ~1.2–1.3×. (reproduced: 25.7 vs 19.7 s; 6.9 vs 5.5 s)
- The audio diagnosis and the `pid_active` fix, as described. (code + earlier listening tests)
- Fan app writes only fan mode/target and runs as a root daemon with a user-side app. (code)

## Need qualification
| Claim | Problem | Suggested wording |
|---|---|---|
| "The app I'm using always runs at full speed" | A demoted app brought to the front took 3–31 s (median 10.8 s) to get full speed back; its child processes outside the app bundle stay demoted | "The frontmost app is put back to full speed at the next scan, usually within a few seconds; in my test it took 3–31 s" |
| "cut CPU power by 81%" (with usual apps open) | Not reproduced at idle in the controlled run (no measurable difference); 81% was measured with music playing in Chrome, i.e. with a busy background app | Tie the number to the situation: "with music playing in a background Chrome tab"; add the idle result |
| "about 44% of that saving" from plain Low Power Mode | Holds for that run and for sustained load (−27% vs −73% system), not at idle | Use the sustained-load numbers; say idle showed no difference |
| "3.5–12.7× slower" | Measured with `taskpolicy` alone on a quiet system; real Extreme mode with ~350 demoted processes: 21–100× (1 job), 25–400× (8 jobs), highly variable | Give the measured range and explain the contention |
| "Every 5 seconds ... about 230 to 300 processes" | 300–380 in these runs | "around 300–380" |
| "Turning the mode off, pausing, a crash and restart, or uninstalling all put every process back" | Mode switches verified repeatedly; crash/uninstall restore is designed and coded but was not tested here | "...is designed to put every process back; I verified it for switching the mode off" |
| "Safe by design: ... can't be driven past what the hardware allows" | Max is clamped; but a failed min/max read can produce a 0 rpm target, and invalid config values (NaN) pass the clamp | Keep the claim for normal operation, mention the edge cases being fixed |
| "macOS 13 or later" | Audio protection needs macOS 14.2; below it Extreme demotes nothing (fail-safe). Fan Curve's GUI uses a macOS 15 API | "macOS 14.2+ (Battery Tool), macOS 15+ (Fan Curve app)" until fixed |
| "Fan Curve keeps the fans higher than Apple would" | Supported: with Apple control the fans stayed at 0 rpm up to 95 °C under load | Add the number |

## Need more testing before claiming
- ~~Battery life~~ — measured 19 Oct with light use: −12% (Low Power Mode), −26% (Extreme) battery drain, n = 2; runtime figures are estimates.
- **"Cooler to the touch"**: chassis temperature not measured; internal sensors only. The `Ts0P` "palm rest" sensor showed no difference in 2-minute windows.
- ~~Fan Auto behaviour vs true Apple control with the daemon stopped~~ — tested 20 Oct: same behaviour (fans off under load in both).

## Technical inaccuracies
- "work marked as background is scheduled onto the efficiency cores" — it is *preferentially* scheduled there; macOS does not promise it. (Here it held completely for the demoted processes.)
- The first chart's caption implies a general result; it is one 10-minute run with a busy background tab.

## Missing methodological details
- Fans fixed at maximum, on AC with charging held, 3 rounds, counterbalanced order, unit of replication.
- That idle power drifted more over time than between modes.
- System power vs CPU power distinction (the earlier tables were CPU power only).

## Clarity
- Lead with the trade-off (cooler under background load, much slower background work), not the best number.
- Show "lower power ≠ lower energy" with the per-task energy table; it is the most interesting result.
