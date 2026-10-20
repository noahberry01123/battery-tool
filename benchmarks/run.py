#!/usr/bin/env python3
"""Benchmark runner: Normal vs macOS Low Power Mode vs Battery Tool Extreme Low Power Mode.

Runs as the normal user. Privileged steps (pmset, powermetrics) go through tools/roothelper.sh,
started once with an admin prompt; it restores Low Power Mode on exit. Battery Tool is switched
with its own CLI (admin user, no sudo). Its previous state is restored at the end.

Every run writes to benchmarks/results/<run_id>/ and never touches earlier runs:
  meta.json          machine, OS, battery, fan state, open apps, parameters, test order
  telemetry.csv      1 s SMC samples for the whole run (system/battery power, temps, fans)
  windows.csv        one row per measured window (condition, scenario, rep, start, end, result)
  procs/<w>_{start,end}.csv   per-process CPU / P-core time snapshots (proccores)
  pm/<w>.plist       powermetrics for the window (CPU/GPU power, cluster residency, frequency)
  battery/<w>_{start,end}.txt ioreg AppleSmartBattery snapshot
  latency/<w>.txt    timer-wakeup latency samples (mixed scenario)
  failures.jsonl     anything that went wrong, never silently dropped
"""
import argparse, json, os, platform, random, shlex, shutil, signal, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.join(HERE, "bin")
BT = "/usr/local/bin/battery-tool"
PY = sys.executable
WORK = os.path.join(HERE, "workloads", "work.py")
PROBE = os.path.join(HERE, "workloads", "latency_probe.py")
CONDITIONS = {"A": "normal", "B": "lowpower", "C": "extreme"}


def sh(cmd, check=False, timeout=120):
    r = subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True, text=True, timeout=timeout)
    if check and r.returncode != 0:
        raise RuntimeError(f"{cmd}: {r.stderr.strip()}")
    return r.stdout


class Run:
    def __init__(self, args):
        self.args = args
        self.id = time.strftime("%Y%m%d-%H%M%S") + "-" + args.label
        self.dir = os.path.join(HERE, "results", self.id)
        for d in ("procs", "pm", "battery", "latency"):
            os.makedirs(os.path.join(self.dir, d), exist_ok=True)
        self.windows = open(os.path.join(self.dir, "windows.csv"), "w")
        self.windows.write("window,condition,scenario,rep,start,end,seconds,result\n")
        self.stage = args.helper or f"/private/tmp/bt-bench-{self.id}"   # root helper's area: TCC blocks root in ~/Documents
        if not args.helper:
            os.makedirs(self.stage, exist_ok=True); os.chmod(self.stage, 0o755)
        self.fifo = os.path.join(self.stage, "helper.fifo")
        self.telemetry = None
        self.bt_before = None

    # ---- bookkeeping ----
    def fail(self, where, err):
        with open(os.path.join(self.dir, "failures.jsonl"), "a") as f:
            f.write(json.dumps({"t": time.time(), "where": where, "error": str(err)}) + "\n")
        print(f"FAILURE {where}: {err}", flush=True)

    def helper(self, line):
        if self.args.no_root:
            return
        with open(self.fifo, "w") as f:
            f.write(line + "\n")
        time.sleep(1)

    def lpm(self):
        out = sh("pmset -g")
        for l in out.splitlines():
            if l.strip().startswith("lowpowermode"):
                return int(l.split()[1])
        return None

    def bt_config(self):
        with open("/usr/local/etc/battery-tool/config.json") as f:
            c = json.load(f)["lowpower"]
        with open("/usr/local/etc/battery-tool/config.json") as f:
            cl = json.load(f)["charge_limit"]
        return {"enabled": c["enabled"], "auto": c["auto_trigger"]["enabled"], "auto_temp": c["auto_trigger"]["temp_c"],
                "limit_max": cl["max_percent"], "limit_resume": cl["resume_percent"]}

    def meta(self, order):
        apps = sh("lsappinfo list 2>/dev/null | sed -n 's/^ *[0-9]*) \"\\(.*\\)\" ASN.*/\\1/p'").split("\n")
        m = {
            "run_id": self.id, "started": time.time(), "label": self.args.label,
            "machine": sh("sysctl -n hw.model").strip(), "chip": sh("sysctl -n machdep.cpu.brand_string").strip(),
            "p_cores": sh("sysctl -n hw.perflevel0.logicalcpu").strip(), "e_cores": sh("sysctl -n hw.perflevel1.logicalcpu").strip(),
            "macos": sh("sw_vers -productVersion").strip(), "build": sh("sw_vers -buildVersion").strip(),
            "power_source": sh("pmset -g batt").splitlines()[0], "battery": sh("ioreg -rn AppleSmartBattery | grep -E '\"(CycleCount|DesignCapacity|AppleRawMaxCapacity|NominalChargeCapacity|Temperature)\" ='"),
            "fans": sh(f"{shlex.quote(os.path.join(BIN, 'fancurve-cli'))} list 2>/dev/null || true"), "open_apps": [a for a in apps if a],
            "battery_tool_before": self.bt_before, "params": vars(self.args), "order": order,
        }
        with open(os.path.join(self.dir, "meta.json"), "w") as f:
            json.dump(m, f, indent=2)

    # ---- conditions ----
    def set_condition(self, c):
        if self.args.dry:
            return
        if c == "A":
            sh(f"{BT} lowpower off"); self.helper("lpm 0")
        elif c == "B":
            sh(f"{BT} lowpower off"); self.helper("lpm 1")
        elif c == "C":
            sh(f"{BT} lowpower off"); self.helper("lpm 0"); sh(f"{BT} lowpower on")
        want = {"A": 0, "B": 1, "C": 1}[c]
        if not self.args.no_root and self.lpm() != want:
            self.fail(f"set_condition {c}", f"Low Power Mode is {self.lpm()}, expected {want}")

    # ---- measurement ----
    def snapshot(self, w, tag):
        with open(os.path.join(self.dir, "procs", f"{w}_{tag}.csv"), "w") as f:
            f.write(sh([os.path.join(BIN, "proccores")]))           # list form: the path contains a space
        with open(os.path.join(self.dir, "battery", f"{w}_{tag}.txt"), "w") as f:
            f.write(sh("ioreg -rn AppleSmartBattery | grep -E '\"(Voltage|Amperage|InstantAmperage|AppleRawCurrentCapacity|Temperature|IsCharging|ExternalConnected)\" ='"))

    def window(self, c, scenario, rep, body):
        w = f"{c}{CONDITIONS[c]}_{scenario}_r{rep}"
        self.snapshot(w, "start"); self.helper(f"pm start {w}")
        start = time.time(); result = ""
        try:
            result = body(w)
        except Exception as e:
            self.fail(w, e); result = "error"
        end = time.time()
        self.helper("pm stop"); self.snapshot(w, "end")
        self.windows.write(f"{w},{CONDITIONS[c]},{scenario},{rep},{start:.3f},{end:.3f},{end-start:.2f},{result}\n")
        self.windows.flush()
        print(f"  {w}: {end-start:.1f} s {result}", flush=True)

    def idle(self, w):
        time.sleep(self.args.idle)
        return "ok"

    def sustained(self, w):
        """8 continuous hashing processes for a fixed time: steady-state power, temperature and core split."""
        ps = [subprocess.Popen([PY, "-I", WORK, "100000000"], stdout=subprocess.DEVNULL) for _ in range(8)]
        time.sleep(self.args.sustained)
        for p in ps:
            p.kill()
        return "ok"

    def light(self, w):
        r = subprocess.run([PY, "-I", os.path.join(HERE, "workloads", "light.py"), str(self.args.idle), "10", "700"],
                           capture_output=True, text=True)
        return r.stdout.strip() or "ok"

    def battery_ok(self):
        """On battery runs: refuse to continue at or below the floor (never deep-discharge)."""
        if not self.args.require_battery:
            return True
        b = sh("pmset -g batt")
        pct = int(b.split("\t")[1].split("%")[0])
        if "Battery Power" not in b:
            self.fail("battery", "not on battery power"); return False
        if pct <= self.args.floor:
            self.fail("battery", f"charge {pct}% at or below floor {self.args.floor}%: stopping"); return False
        return True

    def jobs(self, n, rounds, w, probe=False):
        pr = None
        if probe:
            pr = subprocess.Popen([PY, "-I", PROBE, str(self.args.probe_samples)],
                                  stdout=open(os.path.join(self.dir, "latency", f"{w}.txt"), "w"))
        ps = [subprocess.Popen([PY, "-I", WORK, str(rounds)], stdout=subprocess.PIPE, text=True) for _ in range(n)]
        outs = [p.communicate()[0].strip() for p in ps]          # "<wall s> cpu=.. pshare=.. energy_j=.."
        times = [float(o.split()[0]) if o else float("nan") for o in outs]
        if pr:
            pr.terminate(); pr.wait()                        # latency only while the jobs ran
        slowest = outs[times.index(max(times))].split()[1:] if outs and outs[0] else []
        return f"job_s={max(times):.2f} " + " ".join(slowest)

    # ---- main ----
    def go(self):
        a = self.args
        self.bt_before = self.bt_config()
        conds = list(a.conditions)
        order = []
        for r in range(a.rep_start, a.rep_start + a.reps):
            seq = conds[:] if r % 2 else conds[::-1]          # ABC, CBA, ABC ... (counterbalanced)
            if a.shuffle:
                random.shuffle(seq)
            order += [(r, c) for c in seq]
        self.meta(order)
        # Display state changes whole-system power by ~4-5 W: keep it on for the whole run (as in use).
        self.caff = subprocess.Popen(["caffeinate", "-d", "-i", "-w", str(os.getpid())])
        self.protect_collectors(True)
        tel = open(os.path.join(self.dir, "telemetry.csv"), "w")
        self.telemetry = subprocess.Popen([f"{BIN}/telemetry", "1000", "0"], stdout=tel)
        if not a.no_root and not (a.helper and os.path.exists(self.fifo)):
            helper = os.path.join(self.stage, "roothelper.sh")
            shutil.copy(os.path.join(HERE, "tools", "roothelper.sh"), helper)
            subprocess.Popen(["osascript", "-e", f'do shell script "/bin/bash \'{helper}\' \'{self.stage}\' {a.max_seconds} > /dev/null 2>&1 &" '
                              'with prompt "Battery Tool benchmark: switch Low Power Mode and record powermetrics (restored afterwards)" with administrator privileges'])
            for _ in range(300):                                 # up to 5 min to type the password
                if os.path.exists(self.fifo):
                    break
                time.sleep(1)
            else:
                self.telemetry.terminate()
                self.fail("startup", "root helper did not start (password not entered within 5 min?)")
                raise RuntimeError("root helper did not start")
        try:
            if not a.dry:
                sh(f"{BT} lowpower auto off")
                if a.hold_charge:                                # on AC: stop charging so it adds no heat/power
                    pct = int(sh("pmset -g batt").split("\t")[1].split("%")[0])
                    hold = max(pct, 21)
                    sh(f"{BT} set-limit {hold} {hold - 1}")
                    print(f"holding charge at {hold}%", flush=True)
            for rep, c in order:
                if not self.battery_ok():
                    break
                print(f"rep {rep} condition {c} ({CONDITIONS[c]})", flush=True)
                self.set_condition(c)
                time.sleep(a.settle)
                if "light" in a.scenarios:
                    self.window(c, "light", rep, self.light)
                if "idle" in a.scenarios:
                    self.window(c, "idle", rep, self.idle); time.sleep(a.cooldown)
                if "single" in a.scenarios:
                    self.window(c, "bg_single", rep, lambda w: self.jobs(1, a.single_rounds, w)); time.sleep(a.cooldown)
                if "sustained" in a.scenarios:
                    self.window(c, "sustained8", rep, self.sustained); time.sleep(a.cooldown)
                if "multi" in a.scenarios:
                    self.window(c, "bg_multi", rep, lambda w: self.jobs(8, a.multi_rounds, w, probe=True)); time.sleep(a.cooldown)
        finally:
            self.restore()

    def protect_collectors(self, on):
        """Under Extreme the user-side collectors would be demoted and starved, thinning the samples when the
        E-cores are busiest. Add them to Battery Tool's protected names for the run (config only; restored after).
        The workloads stay demotable."""
        if self.args.dry:
            return
        path = "/usr/local/etc/battery-tool/config.json"
        try:
            with open(path) as f:
                c = json.load(f)
            names = [n for n in c["lowpower"]["protected"] if n not in ("telemetry", "proccores")]
            c["lowpower"]["protected"] = names + (["telemetry", "proccores"] if on else [])
            c["revision"] += 1
            tmp = path + ".bench-tmp"
            with open(tmp, "w") as f:
                json.dump(c, f, indent=2, sort_keys=True)
            os.rename(tmp, path)
        except Exception as e:
            self.fail("protect_collectors", e)

    def restore(self):
        self.protect_collectors(False)
        try:
            with open(os.path.join(self.dir, "display_events.txt"), "w") as f:
                f.write(sh("pmset -g log | grep 'Display is turned'"))
        except Exception as e:
            self.fail("display_events", e)
        if self.args.helper:
            self.helper("pm stop")                              # a shared helper stays up for the next run
        else:
            self.helper("exit")
        time.sleep(5)
        b = self.bt_before or {}
        if self.args.dry:
            b = {}
        try:
            if self.args.dry:
                raise StopIteration

            sh(f"{BT} lowpower off")
            if b.get("auto"):
                sh(f"{BT} lowpower auto on {int(b['auto_temp'])}")
            if b.get("enabled"):
                sh(f"{BT} lowpower on")
            if self.args.hold_charge and b.get("limit_max"):
                sh(f"{BT} set-limit {b['limit_max']} {b['limit_resume']}")
        except StopIteration:
            pass
        except Exception as e:
            self.fail("restore battery-tool", e)
        for name in ("pm", ):
            src = os.path.join(self.stage, name)
            if os.path.isdir(src):
                for fn in os.listdir(src):
                    shutil.copy(os.path.join(src, fn), os.path.join(self.dir, name, fn))
        if os.path.exists(os.path.join(self.stage, "helper.log")):
            shutil.copy(os.path.join(self.stage, "helper.log"), os.path.join(self.dir, "helper.log"))
        if self.telemetry:
            self.telemetry.terminate()
        self.windows.close()
        with open(os.path.join(self.dir, "meta.json")) as f:
            m = json.load(f)
        m["finished"] = time.time(); m["battery_tool_after"] = self.bt_config(); m["lpm_after"] = self.lpm()
        with open(os.path.join(self.dir, "meta.json"), "w") as f:
            json.dump(m, f, indent=2)
        print(f"done: {self.dir}", flush=True)


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--label", default="abc")
    p.add_argument("--conditions", default="ABC")
    p.add_argument("--scenarios", default="idle,sustained,single,multi")
    p.add_argument("--reps", type=int, default=3)
    p.add_argument("--rep-start", type=int, default=1, help="number of the first round (to redo a specific round)")
    p.add_argument("--shuffle", action="store_true")
    p.add_argument("--settle", type=int, default=30)
    p.add_argument("--idle", type=int, default=120)
    p.add_argument("--cooldown", type=int, default=30)
    p.add_argument("--single-rounds", type=int, default=46000)
    p.add_argument("--multi-rounds", type=int, default=12000)
    p.add_argument("--probe-samples", type=int, default=2000)
    p.add_argument("--max-seconds", type=int, default=3 * 3600)
    p.add_argument("--sustained", type=int, default=90, help="seconds of the sustained 8-process window")
    p.add_argument("--require-battery", action="store_true", help="battery test: must be unplugged; stops at --floor")
    p.add_argument("--floor", type=int, default=20, help="stop when charge <= this %%")
    p.add_argument("--hold-charge", action="store_true", help="on AC: hold the battery at its current % during the run")
    p.add_argument("--helper", help="reuse an already-running root helper's folder (no new admin prompt)")
    p.add_argument("--no-root", action="store_true", help="skip pmset/powermetrics")
    p.add_argument("--dry", action="store_true", help="change no settings at all (implies --no-root): tests the pipeline in the current state")
    args = p.parse_args()
    if args.dry:
        args.no_root = True
    Run(args).go()
