#!/usr/bin/env python3
"""Combine a main run with a redo run into a new folder, replacing named windows.

The original run folders are never modified. Every replaced window is listed in MERGE.txt with the reason.
Usage: merge.py <main_run> <redo_run> <reason> <window> [<window> ...]
Output: <main_run>-merged/
"""
import csv, os, shutil, sys

main, redo, reason, replace = sys.argv[1].rstrip("/"), sys.argv[2].rstrip("/"), sys.argv[3], set(sys.argv[4:])
out = main + "-merged"
if os.path.exists(out):
    sys.exit(f"{out} exists; not overwriting")
os.makedirs(out)


def win_file(run):
    f = os.path.join(run, "windows_recovered.csv")
    return f if os.path.exists(f) else os.path.join(run, "windows.csv")


main_rows = [r for r in csv.DictReader(open(win_file(main))) if r["window"] not in replace]
redo_rows = [r for r in csv.DictReader(open(win_file(redo))) if r["window"] in replace]
missing = replace - {r["window"] for r in redo_rows}
if missing:
    sys.exit(f"redo run lacks: {sorted(missing)}")
rows = sorted(main_rows + redo_rows, key=lambda r: float(r["start"]))
with open(os.path.join(out, "windows.csv"), "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0].keys())); w.writeheader(); w.writerows(rows)

tel = []
for run in (main, redo):
    with open(os.path.join(run, "telemetry.csv")) as f:
        header = f.readline(); tel += [l for l in f if l.strip()]
tel.sort(key=lambda l: float(l.split(",")[0]))
open(os.path.join(out, "telemetry.csv"), "w").write(header + "".join(tel))

for sub in ("procs", "pm", "battery", "latency"):
    os.makedirs(os.path.join(out, sub), exist_ok=True)
    for run, keep in ((main, lambda n: not any(n.startswith(x + "_") or n.startswith(x + ".") for x in replace)),
                      (redo, lambda n: any(n.startswith(x + "_") or n.startswith(x + ".") for x in replace))):
        d = os.path.join(run, sub)
        for n in (os.listdir(d) if os.path.isdir(d) else []):
            if keep(n):
                shutil.copy(os.path.join(d, n), os.path.join(out, sub, n))
shutil.copy(os.path.join(main, "meta.json"), os.path.join(out, "meta.json"))
with open(os.path.join(out, "MERGE.txt"), "w") as f:
    f.write(f"main run: {os.path.basename(main)}\nredo run: {os.path.basename(redo)}\nreason: {reason}\nreplaced windows:\n")
    f.writelines(f"  {x}\n" for x in sorted(replace))
print("merged into", out)
