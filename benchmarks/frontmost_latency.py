#!/usr/bin/env python3
"""How long does Extreme Low Power Mode take to give a newly frontmost app full speed again?

Requires Extreme mode ON (run.py restores the user's previous state, this script does not change it).
Per trial: launch TextEdit hidden (`open -g`), wait until Battery Tool has demoted it (external darwin-bg
flag set), bring it to the front (`open -a`), then poll its flag every 50 ms until it is cleared.
Opens an empty TextEdit window, touches no files, and quits TextEdit at the end (no save prompt:
the untitled document is unmodified).
Output: results/<run_id>/frontmost.csv
"""
import csv, os, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
PROC = os.path.join(HERE, "bin", "proccores")
APP = "TextEdit"


def textedit():
    """(pid, ext_darwin_bg) of the running TextEdit, or (None, None)."""
    for line in subprocess.run([PROC], capture_output=True, text=True).stdout.splitlines():
        if line.endswith(f'"{APP}"'):
            f = line.split(",")
            return int(f[0]), f[3] == "1"
    return None, None


def main(trials=10, demote_timeout=30, restore_timeout=30):
    if "on" not in subprocess.run(["/usr/local/bin/battery-tool", "lowpower", "status"], capture_output=True, text=True).stdout.split("Extreme LPM:")[1].split("\n")[0]:
        sys.exit("Extreme Low Power Mode must be on")
    run_id = time.strftime("%Y%m%d-%H%M%S") + "-frontmost"
    out = os.path.join(HERE, "results", run_id); os.makedirs(out)
    w = csv.writer(open(os.path.join(out, "frontmost.csv"), "w"))
    w.writerow(["trial", "pid", "demote_wait_s", "restore_latency_s", "status"])
    for t in range(1, trials + 1):
        subprocess.run(["open", "-g", "-a", APP]); time.sleep(1)
        subprocess.run(["open", "-a", "Finder"])                 # make sure TextEdit is not frontmost
        start = time.time(); pid, bg = textedit()
        while not bg and time.time() - start < demote_timeout:
            time.sleep(0.2); pid, bg = textedit()
        demote_wait = time.time() - start
        if not bg:
            w.writerow([t, pid, f"{demote_wait:.2f}", "", "never demoted"]); continue
        t0 = time.time(); subprocess.run(["open", "-a", APP])
        while bg and time.time() - t0 < restore_timeout:
            time.sleep(0.05); _, bg = textedit()
        lat = time.time() - t0
        w.writerow([t, pid, f"{demote_wait:.2f}", f"{lat:.2f}" if not bg else "", "ok" if not bg else "not restored in time"])
        print(f"trial {t}: demoted after {demote_wait:.1f} s, restored {lat:.2f} s after coming to the front", flush=True)
        time.sleep(2)
    subprocess.run(["osascript", "-e", f'quit app "{APP}"'], capture_output=True)
    print("done:", out)


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 10)
