#!/bin/bash
# Builds the read-only collectors into benchmarks/bin. No root, no SMC writes.
set -euo pipefail
cd "$(dirname "$0")"; mkdir -p bin
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}
F="-framework IOKit -framework CoreFoundation -framework CoreAudio"
clang -O2 -o bin/telemetry tools/telemetry.c ../Sources/CSMC/smc.c $F
clang -O2 -o bin/proccores tools/proccores.c ../Sources/CSMC/smc.c $F
# FanCurve's CLI, used read-only here (list / get) to record fan state in meta.json.
FC=${FANCURVE_DIR:-../../fancurve}
[ -f "$FC/main.c" ] && clang -O2 -o bin/fancurve-cli "$FC/main.c" "$FC/smc.c" -framework IOKit -framework CoreFoundation || echo "fancurve source not found; skipping fancurve-cli"
echo "built: $(ls bin | tr '\n' ' ')"
