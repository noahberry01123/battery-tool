# Battery test summary

| Condition | n | System power, SMC PSTR (W) | Battery power, SMC PPBR (W) | Charge used (mAh/h, ioreg) | Estimated runtime, full battery* | CPU temp (°C) | Battery temp (°C) |
|---|---|---|---|---|---|---|---|
| Normal | 2 | 8.50 ± 0.53 | 9.55 | 662 ± 55 | 6.8 h | 52.6 | 25.8 |
| Low Power Mode | 2 | 7.41 ± 0.09 | 8.49 | 604 ± 19 | 7.5 h | 49.3 | 25.5 |
| Extreme LPM | 2 | 5.42 ± 0.01 | 6.57 | 449 ± 4 | 10.0 h | 44.2 | 25.4 |

Relative to Normal: Low Power Mode: -9% charge, -13% system power; Extreme LPM: -32% charge, -36% system power

*Estimate = present full capacity (4501 mAh, ioreg AppleRawMaxCapacity) ÷ charge used per hour, for this light workload. Not a measured full discharge; the capacity figure of an aged cell (77% health) is itself an estimate. SMC PPBR reads ~12% above both PSTR and the charge counter and is shown for reference only.
