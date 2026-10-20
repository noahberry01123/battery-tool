# Fan test summary

| Mode | Phase | n | CPU temp, last 60 s (°C) | Peak (°C) | Fan 0 (rpm) | System power (W) | Time to steady / half-cool (s) |
|---|---|---|---|---|---|---|---|
| Fan daemon stopped (Apple firmware) | load | 2 | 93.4 ± 0.1 | 97.4 | 1159 | 34.4 | 109 |
| Fan daemon stopped (Apple firmware) | cool | 2 | 69.1 ± 1.9 | 96.8 | 2315 | 16.6 | 6 |
| Fan app Auto (re-asserts auto every 2 s) | load | 2 | 93.0 ± 0.3 | 99.1 | 2317 | 36.2 | 73 |
| Fan app Auto (re-asserts auto every 2 s) | cool | 2 | 63.4 ± 0.2 | 97.0 | 5732 | 17.4 | 11 |

Aborted windows: app_auto r1, app_auto r2, firmware r2
