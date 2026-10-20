#!/usr/bin/env python3
"""Fan control comparison: Apple automatic vs the fan app's Curve vs Manual 100%.

Changes ONLY the installed fan app's own config file (MacFanCtl / FanCurve), which its root daemon
applies every 2 s and clamps to each fan's SMC min/max. No SMC writes from here, no root.

Per fan mode, per round: settle -> heat load (8 hashing processes, Normal mode) -> cool-down,
with 1 s telemetry (CPU temperature, fan RPM, system power).
Safety: if the hottest CPU sensor stays >= 95 C for 10 s, the load is stopped and fans are set to
Manual 100% (the safe direction). The original config is restored on exit, error or Ctrl-C.
Battery Tool's Extreme mode is switched off for the test and restored afterwards.
Output: results/<run_id>/ (fan_windows.csv, telemetry.csv, meta.json).
"""
import argparse, json, os, signal, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.join(HERE, "bin")
BT = "/usr/local/bin/battery-tool"
PY = sys.executable
WORK = os.path.join(HERE, "workloads", "work.py")
CONFIGS = ["/Library/Application Support/MacFanCtl/config", "/Library/Application Support/FanCurve/config"]


def find_config():
    for c in CONFIGS:
        if os.path.exists(c) and os.access(c, os.W_OK):
            return c
    sys.exit("no writable fan app config found")


def write_cfg(path, mode, percent, low, high):
    tmp = path + ".bench-tmp"
    with open(tmp, "w") as f:
        f.write(f"mode {mode}\npercent {percent}\nlow {low}\nhigh {high}\n")
    os.rename(tmp, path)                                         # atomic: the daemon never reads half a file


def last_cpu_c(tel_path):
    try:
        with open(tel_path, "rb") as f:
            f.seek(-400, 2); line = f.read().decode().strip().splitlines()[-1].split(",")
        return float(line[3]) if line[3] else None
    except Exception:
        return None


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--reps", type=int, default=2)
    p.add_argument("--settle", type=int, default=120)
    p.add_argument("--load", type=int, default=180)
    p.add_argument("--cool", type=int, default=180)
    p.add_argument("--curve-low", type=float, default=55)
    p.add_argument("--curve-high", type=float, default=90)
    a = p.parse_args()

    cfg = find_config()
    original = open(cfg).read()
    run_id = time.strftime("%Y%m%d-%H%M%S") + "-fans"
    out = os.path.join(HERE, "results", run_id); os.makedirs(out)
    bt_cfg = json.load(open("/usr/local/etc/battery-tool/config.json"))
    bt_before, limit_before = bt_cfg["lowpower"], bt_cfg["charge_limit"]
    modes = [("auto", "auto", 50), ("curve", "curve", 50), ("manual100", "manual", 100)]
    order = [m for r in range(a.reps) for m in (modes if r % 2 == 0 else modes[::-1])]
    json.dump({"run_id": run_id, "config_file": cfg, "original_config": original, "params": vars(a),
               "order": [m[0] for m in order], "fans": subprocess.run([f"{BIN}/fancurve-cli", "list"], capture_output=True, text=True).stdout,
               "note": "Installed fan daemon tested as-is; it clamps targets to F<n>Mn..Mx."},
              open(os.path.join(out, "meta.json"), "w"), indent=2)
    tel_path = os.path.join(out, "telemetry.csv")
    tel = subprocess.Popen([f"{BIN}/telemetry", "1000", "0"], stdout=open(tel_path, "w"))
    win = open(os.path.join(out, "fan_windows.csv"), "w"); win.write("mode,rep,phase,start,end,aborted\n")
    jobs = []

    def stop_jobs():
        for j in jobs:
            if j.poll() is None:
                j.kill()
        jobs.clear()

    def restore(*_):
        stop_jobs()
        with open(cfg + ".bench-tmp", "w") as f:
            f.write(original)
        os.rename(cfg + ".bench-tmp", cfg)
        if bt_before.get("auto_trigger", {}).get("enabled"):
            subprocess.run([BT, "lowpower", "auto", "on", str(int(bt_before["auto_trigger"]["temp_c"]))], capture_output=True)
        if bt_before.get("enabled"):
            subprocess.run([BT, "lowpower", "on"], capture_output=True)
        subprocess.run([BT, "set-limit", str(limit_before["max_percent"]), str(limit_before["resume_percent"])], capture_output=True)
        tel.terminate(); win.close()
        print("restored fan config and Battery Tool settings", flush=True)

    signal.signal(signal.SIGTERM, lambda *_: (restore(), sys.exit(1)))
    try:
        subprocess.run([BT, "lowpower", "auto", "off"], capture_output=True)
        subprocess.run([BT, "lowpower", "off"], capture_output=True)
        b = subprocess.run(["pmset", "-g", "batt"], capture_output=True, text=True).stdout
        if "AC Power" in b:                                      # hold the charge: no charging heat during the test
            hold = max(int(b.split("\t")[1].split("%")[0]), 21)
            subprocess.run([BT, "set-limit", str(hold), str(hold - 1)], capture_output=True)
        rep_of = {}
        for name, mode, pct in order:
            rep_of[name] = rep_of.get(name, 0) + 1; rep = rep_of[name]
            print(f"{name} round {rep}", flush=True)
            write_cfg(cfg, mode, pct, a.curve_low, a.curve_high)
            for phase, secs in (("settle", a.settle), ("load", a.load), ("cool", a.cool)):
                start = time.time(); aborted = ""
                if phase == "load":
                    jobs.extend(subprocess.Popen([PY, "-I", WORK, "10000000"], stdout=subprocess.DEVNULL) for _ in range(8))
                hot_since = None
                while time.time() - start < secs:
                    time.sleep(1)
                    t = last_cpu_c(tel_path)
                    if t is not None and t >= 95:
                        hot_since = hot_since or time.time()
                        if time.time() - hot_since >= 10:
                            stop_jobs(); write_cfg(cfg, "manual", 100, a.curve_low, a.curve_high)
                            aborted = f"cpu {t:.1f}C >= 95C for 10 s: load stopped, fans to 100%"; print(aborted, flush=True)
                            break
                    else:
                        hot_since = None
                stop_jobs()
                win.write(f"{name},{rep},{phase},{start:.3f},{time.time():.3f},{aborted}\n"); win.flush()
    finally:
        restore()
    print("done:", out)


if __name__ == "__main__":
    main()
