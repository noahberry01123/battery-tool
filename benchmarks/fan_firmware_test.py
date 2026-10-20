#!/usr/bin/env python3
"""Apple's own fan control (fan daemon stopped) vs the fan app's Auto mode (daemon running, re-asserting "auto").

Answers one question from fan_test.py: does the app's Auto mode, which writes F<n>Md=0 every 2 s, behave like
true firmware control? Same 8-process load for both, order firmware / app_auto / app_auto / firmware.

Privileged steps go through tools/roothelper.sh (one admin prompt): `fand stop` = launchctl bootout of the fan
daemon (its SIGTERM handler returns the fans to Apple's control), `fand start` = bootstrap it again. The helper
also starts the daemon again on exit. The fan app's config is restored at the end, as are Battery Tool settings.
Safety: if the hottest CPU sensor stays >= 95 C for 10 s the load stops (with the daemon running, fans are also set
to Manual 100%). With the daemon stopped, Apple's firmware and the chip's own throttling remain in charge.
Output: results/<run_id>-fanfw/ (fan_windows.csv, telemetry.csv, meta.json, helper.log)
"""
import json, os, shutil, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.join(HERE, "bin")
BT = "/usr/local/bin/battery-tool"
PY = sys.executable
WORK = os.path.join(HERE, "workloads", "work.py")
CFG = next((c for c in ["/Library/Application Support/MacFanCtl/config", "/Library/Application Support/FanCurve/config"]
            if os.path.exists(c)), None)


def write_cfg(text):
    with open(CFG + ".bench-tmp", "w") as f:
        f.write(text)
    os.rename(CFG + ".bench-tmp", CFG)


def last_cpu_c(path):
    try:
        with open(path, "rb") as f:
            f.seek(-400, 2); line = f.read().decode().strip().splitlines()[-1].split(",")
        return float(line[3]) if line[3] else None
    except Exception:
        return None


def main(settle=120, load=180, cool=180):
    if not CFG:
        sys.exit("fan app config not found")
    run_id = time.strftime("%Y%m%d-%H%M%S") + "-fanfw"
    out = os.path.join(HERE, "results", run_id); os.makedirs(out)
    reuse = sys.argv[1] if len(sys.argv) > 1 else None             # an already-running helper's folder
    stage = reuse or f"/private/tmp/bt-bench-{run_id}"
    if not reuse:
        os.makedirs(stage); os.chmod(stage, 0o755)
    fifo = os.path.join(stage, "helper.fifo")
    original_cfg = open(CFG).read()
    btc = json.load(open("/usr/local/etc/battery-tool/config.json")); bt_before, limit_before = btc["lowpower"], btc["charge_limit"]
    order = ["firmware", "app_auto", "app_auto", "firmware"]
    json.dump({"run_id": run_id, "config_file": CFG, "original_config": original_cfg, "order": order,
               "params": {"settle": settle, "load": load, "cool": cool}}, open(os.path.join(out, "meta.json"), "w"), indent=2)

    if not (reuse and os.path.exists(fifo)):
      shutil.copy(os.path.join(HERE, "tools", "roothelper.sh"), os.path.join(stage, "roothelper.sh"))
      subprocess.Popen(["osascript", "-e", f'do shell script "/bin/bash \'{stage}/roothelper.sh\' \'{stage}\' 7200 > /dev/null 2>&1 &" '
                      'with prompt "Fan test: stop and restart the fan daemon to compare with Apple fan control (restored afterwards)" with administrator privileges'])
    for _ in range(600):
        if os.path.exists(fifo):
            break
        time.sleep(1)
    else:
        sys.exit("root helper did not start")

    def helper(line):
        with open(fifo, "w") as f:
            f.write(line + "\n")
        time.sleep(2)

    helper("lpm 0")                                           # same power state for every round (normal clocks)
    lpm_now = subprocess.run(["pmset", "-g"], capture_output=True, text=True).stdout
    lpm_val = next((l.split()[1] for l in lpm_now.splitlines() if l.strip().startswith("lowpowermode")), "?")
    print("Low Power Mode during the test:", lpm_val, flush=True)
    m = json.load(open(os.path.join(out, "meta.json"))); m["lowpowermode"] = lpm_val
    json.dump(m, open(os.path.join(out, "meta.json"), "w"), indent=2)

    tel_path = os.path.join(out, "telemetry.csv")
    tel = subprocess.Popen([f"{BIN}/telemetry", "1000", "0"], stdout=open(tel_path, "w"))
    win = open(os.path.join(out, "fan_windows.csv"), "w"); win.write("mode,rep,phase,start,end,aborted\n")
    jobs = []
    try:
        subprocess.run([BT, "lowpower", "auto", "off"], capture_output=True)
        subprocess.run([BT, "lowpower", "off"], capture_output=True)
        b = subprocess.run(["pmset", "-g", "batt"], capture_output=True, text=True).stdout
        if "AC Power" in b:
            hold = max(int(b.split("\t")[1].split("%")[0]), 21)
            subprocess.run([BT, "set-limit", str(hold), str(hold - 1)], capture_output=True)
        reps = {}
        for mode in order:
            reps[mode] = reps.get(mode, 0) + 1
            if mode == "firmware":
                helper("fand stop")
            else:
                helper("fand start"); write_cfg("mode auto\npercent 50\nlow 55\nhigh 90\n")
            print(f"{mode} round {reps[mode]}: fans {subprocess.run([f'{BIN}/fancurve-cli', 'list'], capture_output=True, text=True).stdout.split(chr(10))[1:3]}", flush=True)
            for phase, secs in (("settle", settle), ("load", load), ("cool", cool)):
                start = time.time(); aborted = ""; hot = None
                if phase == "load":
                    jobs.extend(subprocess.Popen([PY, "-I", WORK, "100000000"], stdout=subprocess.DEVNULL) for _ in range(8))
                while time.time() - start < secs:
                    time.sleep(1); t = last_cpu_c(tel_path)
                    if t is not None and t >= 95:
                        hot = hot or time.time()
                        if time.time() - hot >= 10:
                            for j in jobs:
                                j.kill()
                            jobs.clear()
                            if mode == "app_auto":
                                write_cfg("mode manual\npercent 100\nlow 55\nhigh 90\n")
                            aborted = f"cpu {t:.1f}C >= 95C for 10 s: load stopped"; print(aborted, flush=True); break
                    else:
                        hot = None
                for j in jobs:
                    j.kill()
                jobs.clear()
                win.write(f"{mode},{reps[mode]},{phase},{start:.3f},{time.time():.3f},{aborted}\n"); win.flush()
    finally:
        for j in jobs:
            j.kill()
        helper("fand start")
        write_cfg(original_cfg)
        if not reuse:
            helper("exit")
        time.sleep(5)
        if bt_before.get("auto_trigger", {}).get("enabled"):
            subprocess.run([BT, "lowpower", "auto", "on", str(int(bt_before["auto_trigger"]["temp_c"]))], capture_output=True)
        if bt_before.get("enabled"):
            subprocess.run([BT, "lowpower", "on"], capture_output=True)
        subprocess.run([BT, "set-limit", str(limit_before["max_percent"]), str(limit_before["resume_percent"])], capture_output=True)
        tel.terminate(); win.close()
        if os.path.exists(os.path.join(stage, "helper.log")):
            shutil.copy(os.path.join(stage, "helper.log"), os.path.join(out, "helper.log"))
        print("restored; fan daemon running:", bool(subprocess.run(["pgrep", "-f", "macfanctld|fancurved"], capture_output=True).stdout), flush=True)
    print("done:", out)


if __name__ == "__main__":
    main()
