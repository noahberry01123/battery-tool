# Fan test summary

| Mode | Phase | n | CPU temp, last 60 s (°C) | Peak (°C) | Fan 0 (rpm) | System power (W) | Time to steady / half-cool (s) |
|---|---|---|---|---|---|---|---|
| Fan daemon stopped (Apple firmware) | load | 2 | 95.3 ± 1.8 | 98.5 | 1159 | 32.9 | 38 |
| Fan daemon stopped (Apple firmware) | cool | 2 | 96.9 ± 0.4 | 99.0 | 1159 | 33.8 | 4 |
| Fan app Auto (re-asserts auto every 2 s) | load | 2 | 89.3 ± 8.0 | 99.0 | 4021 | 33.6 | 1 |
| Fan app Auto (re-asserts auto every 2 s) | cool | 2 | 84.6 ± 2.8 | 92.5 | 5756 | 32.9 | 77 |

Aborted windows: firmware r1, firmware r1, app_auto r2, firmware r2, firmware r2
