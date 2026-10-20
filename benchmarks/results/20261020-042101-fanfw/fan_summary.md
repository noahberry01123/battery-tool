# Fan test summary

| Mode | Phase | n | CPU temp, last 60 s (°C) | Peak (°C) | Fan 0 (rpm) | System power (W) | Time to steady / half-cool (s) |
|---|---|---|---|---|---|---|---|
| Fan daemon stopped (Apple firmware) | load | 2 | 76.8 ± 2.9 | 79.6 | 919 | 24.1 | 128 |
| Fan daemon stopped (Apple firmware) | cool | 2 | 60.2 ± 0.5 | 78.9 | 0 | 11.3 | 22 |
| Fan app Auto (re-asserts auto every 2 s) | load | 2 | 80.6 ± 0.1 | 83.3 | 0 | 26.6 | 124 |
| Fan app Auto (re-asserts auto every 2 s) | cool | 2 | 63.3 ± 0.9 | 82.0 | 1151 | 14.4 | 29 |

Aborted windows: none
