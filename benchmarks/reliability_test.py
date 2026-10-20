#!/usr/bin/env python3
"""Reliability: does Battery Tool keep its process-policy bookkeeping right across a daemon crash and sleep/wake?

Steps (Extreme mode switched by the CLI; privileged steps via tools/roothelper.sh, one admin prompt):
  S0  Extreme off             -> baseline: processes macOS itself keeps in darwin background
  S1  Extreme on, 30 s        -> demoted set vs the change record
  S2  daemon SIGKILL          -> launchd restarts it; it should restore everything, then re-demote; time it
  S3  sleep ~2 min, auto-wake -> state after wake; Low Power Mode still on?
  S4  Extreme off, 30 s       -> everything Battery Tool demoted must be back to normal
Checks per snapshot: demoted-but-unrecorded processes (leaks), recorded-but-not-demoted entries, frontmost app
demoted, change record parses, Low Power Mode per power source. Restores the previous Battery Tool state at the end.
Output: results/<run_id>-reliability/ (steps.json, snapshots/*.csv, changes_*.tsv, helper.log)
"""
import csv, io, json, os, re, shutil, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.join(HERE, "bin")
BT = "/usr/local/bin/battery-tool"
REC = "/usr/local/var/battery-tool/changes.tsv"


def sh(args):
    return subprocess.run(args, capture_output=True, text=True).stdout


def snapshot(out, tag):
    text = sh([os.path.join(BIN, "proccores")])
    open(os.path.join(out, "snapshots", f"{tag}.csv"), "w").write(text)
    rows = list(csv.DictReader(io.StringIO("".join(l for l in text.splitlines(True) if not l.startswith("#")))))
    uid = str(os.getuid())
    return {(r["pid"], r["start_sec"]): r["name"] for r in rows if r["uid"] == uid and r["ext_darwin_bg"] == "1"}


def record(out, tag):
    try:
        text = open(REC).read()
    except FileNotFoundError:
        text = ""
    open(os.path.join(out, f"changes_{tag}.tsv"), "w").write(text)
    procs, bad = set(), 0
    for l in text.splitlines():
        if l.startswith("proc\t"):
            f = l.split("\t")
            if len(f) >= 7 and f[1].isdigit() and f[2].isdigit():
                procs.add((f[1], f[2]))
            else:
                bad += 1
    return procs, bad, bool(text)


def lpm():
    out = sh(["pmset", "-g", "custom"]); res = {}; src = None
    for l in out.splitlines():
        if l.endswith("Power:"):
            src = "battery" if "Battery" in l else "ac"
        elif l.strip().startswith("lowpowermode") and src:
            res[src] = int(l.split()[1])
    return res


def frontmost_pid():
    asn = sh(["lsappinfo", "front"]).strip()
    m = re.search(r'"pid"=(\d+)', sh(["lsappinfo", "info", "-only", "pid", asn])) if asn else None
    return m.group(1) if m else None


def daemon_pid():
    p = sh(["pgrep", "-f", "/usr/local/bin/battery-tool daemon"]).split()
    return p[0] if p else None


def main():
    run_id = time.strftime("%Y%m%d-%H%M%S") + "-reliability"
    out = os.path.join(HERE, "results", run_id); os.makedirs(os.path.join(out, "snapshots"))
    reuse = sys.argv[1] if len(sys.argv) > 1 else None             # an already-running helper's folder
    stage = reuse or f"/private/tmp/bt-bench-{run_id}"
    fifo = os.path.join(stage, "helper.fifo")
    if not reuse:
        os.makedirs(stage); os.chmod(stage, 0o755)
        shutil.copy(os.path.join(HERE, "tools", "roothelper.sh"), os.path.join(stage, "roothelper.sh"))
    if not (reuse and os.path.exists(fifo)):
        subprocess.Popen(["osascript", "-e", f'do shell script "/bin/bash \'{stage}/roothelper.sh\' \'{stage}\' 1800 > /dev/null 2>&1 &" '
                      'with prompt "Reliability test: restart the Battery Tool daemon and sleep the Mac for 2 minutes" with administrator privileges'])
    for _ in range(600):
        if os.path.exists(fifo):
            break
        time.sleep(1)
    else:
        sys.exit("root helper did not start")

    def helper(line):
        with open(fifo, "w") as f:
            f.write(line + "\n")
        time.sleep(1)

    cfg = json.load(open("/usr/local/etc/battery-tool/config.json"))["lowpower"]
    steps = []
    base = {}

    def check(tag, extra=None):
        demoted = snapshot(out, tag); rec, bad, exists = record(out, tag)
        ours = {k: v for k, v in demoted.items() if k not in base}       # beyond what macOS itself backgrounds
        leaks = {k: v for k, v in ours.items() if k not in rec}
        missing = [k for k in rec if k not in demoted]
        fp = frontmost_pid()
        s = {"step": tag, "t": time.time(), "demoted_total": len(demoted), "demoted_beyond_baseline": len(ours),
             "recorded": len(rec), "demoted_not_recorded": len(leaks), "leak_examples": sorted(set(leaks.values()))[:10],
             "recorded_not_demoted": len(missing), "record_malformed_lines": bad, "record_exists": exists,
             "frontmost_pid": fp, "frontmost_demoted": any(k[0] == fp for k in demoted), "lpm": lpm(), "daemon_pid": daemon_pid()}
        if extra:
            s.update(extra)
        steps.append(s)
        print(json.dumps({k: s[k] for k in ("step", "demoted_beyond_baseline", "recorded", "demoted_not_recorded",
                                            "recorded_not_demoted", "frontmost_demoted", "lpm")}), flush=True)
        json.dump(steps, open(os.path.join(out, "steps.json"), "w"), indent=2)

    try:
        sh([BT, "lowpower", "auto", "off"]); sh([BT, "lowpower", "off"]); helper("lpm 0"); time.sleep(20)
        base.update(snapshot(out, "S0_baseline"))
        check("S0_off")
        sh([BT, "lowpower", "on"]); time.sleep(30)
        check("S1_on")

        old = daemon_pid(); t0 = time.time(); helper("bt kill9")
        new = None
        while time.time() - t0 < 90:
            new = daemon_pid()
            if new and new != old:
                break
            time.sleep(0.5)
        restart_s = time.time() - t0 if new and new != old else None
        time.sleep(60)
        check("S2_after_kill9", {"old_daemon_pid": old, "new_daemon_pid": new, "restart_s": restart_s})

        helper("wake 150"); time.sleep(2); t_sleep = time.time(); helper("sleepnow")
        time.sleep(200)                                   # covers the sleep and the wake
        gap = time.time() - t_sleep
        time.sleep(30)
        check("S3_after_wake", {"slept_wall_s": gap})

        sh([BT, "lowpower", "off"]); time.sleep(30)
        check("S4_off_again")
    finally:
        helper("exit"); time.sleep(5)
        if cfg.get("auto_trigger", {}).get("enabled"):
            sh([BT, "lowpower", "auto", "on", str(int(cfg["auto_trigger"]["temp_c"]))])
        if cfg.get("enabled"):
            sh([BT, "lowpower", "on"])
        if os.path.exists(os.path.join(stage, "helper.log")):
            shutil.copy(os.path.join(stage, "helper.log"), os.path.join(out, "helper.log"))
        subprocess.run(["sh", "-c", f"grep -E 'daemon starting|change record|extreme low power mode (ON|OFF)|sleep|wake' "
                        f"/usr/local/var/battery-tool/log/battery-tool.log | tail -40 > '{out}/daemon_log_tail.txt'"])
    print("done:", out)


if __name__ == "__main__":
    main()
