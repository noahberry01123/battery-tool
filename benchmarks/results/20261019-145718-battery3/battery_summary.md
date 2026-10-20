# Battery test summary

| Condition | n | System power, SMC PSTR (W) | Battery power, SMC PPBR (W) | Charge used (mAh/h, ioreg) | Estimated runtime, full battery* | CPU temp (°C) | Battery temp (°C) |
|---|---|---|---|---|---|---|---|
| Normal | 2 | 8.08 ± 1.35 | 9.16 | 718 ± 104 | 6.4 h | 50.1 | 24.7 |
| Low Power Mode | 2 | 7.00 ± 0.82 | 8.10 | 638 ± 4 | 7.1 h | 47.1 | 24.7 |
| Extreme LPM | 2 | 5.62 ± 0.45 | 6.75 | 540 ± 58 | 8.4 h | 44.3 | 24.7 |

Relative to Normal: Low Power Mode: -11% charge, -13% system power; Extreme LPM: -25% charge, -30% system power

*Estimate = present full capacity (4559 mAh, ioreg AppleRawMaxCapacity) ÷ charge used per hour, for this light workload. Not a measured full discharge; the capacity figure of an aged cell (77% health) is itself an estimate. SMC PPBR reads ~12% above both PSTR and the charge counter and is shown for reference only.
