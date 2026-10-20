import Foundation

/// Extreme low power mode: macOS Low Power Mode on battery AND AC, plus every eligible
/// user process moved to darwin background (`taskpolicy -b`: efficiency cores, low I/O
/// and network priority). This approximates E-core-only operation; macOS does not allow
/// disabling performance cores on Apple Silicon. System processes, protected apps and the
/// frontmost app keep full speed. Every change is written to the ChangeRecord before it
/// is made, so it can always be undone. Used from the daemon's main queue only.
final class LowPowerManager {
    private let log: Logger
    private let recordPath: String
    private var record: ChangeRecord
    private var active = false
    private var trigger: String?
    private var lastScanAt: Double?                       // epoch, for status
    private var activeSince: UInt64?                      // epoch seconds of the first scan since activation
    private var lastScanUptime = -Double.infinity         // monotonic, for scheduling
    private var lastRestoreUptime = -Double.infinity
    private var frontmostName: String?
    private var frontmostUnknown = false
    private var note: String?
    private var refused = Set<String>()                   // "pid/start" that taskpolicy -b failed for; not retried
    private var liveLPM: (battery: Int?, ac: Int?, at: Double)?
    private var audio = AudioProtect()

    init(log: Logger, recordPath: String = Paths.changeRecord) {
        self.log = log
        self.recordPath = recordPath
        // Keep a previous run's leftovers in memory so a later save cannot drop them.
        record = ChangeRecord.load(path: recordPath) ?? ChangeRecord()
    }

    /// Called by the daemon every tick. Applies/removes extreme LPM; runs the process scan when due
    /// (every config.lowpower.scanIntervalSeconds). trigger: "manual" | "auto" | nil (nil when desired == false);
    /// reason: why it is wanted or not (logged when that changes the state).
    func reconcile(desired: Bool, trigger: String?, reason: String, config: Config, consoleUser: ConsoleUser?) {
        let now = ProcessInfo.processInfo.systemUptime
        let interval = Double(config.lowpower.scanIntervalSeconds) - 0.5      // tolerate timer jitter
        guard desired else {
            // Also retry whatever an earlier restore could not undo, at most once per interval.
            if active || (!record.isEmpty && now - lastRestoreUptime >= interval) {
                restoreAll(reason: active ? reason : "retrying an incomplete restore")
            }
            return
        }
        self.trigger = trigger
        if !active {
            log.info("extreme low power mode ON — \(reason): approximates E-core-only operation; "
                     + "macOS does not allow disabling performance cores on Apple Silicon")
            activeSince = UInt64(Date().timeIntervalSince1970)
            record.since = record.since ?? activeSince
            applyLowPowerMode()
            active = true
            scan(config: config, consoleUser: consoleUser)
        } else if now - lastScanUptime >= interval {
            scan(config: config, consoleUser: consoleUser)
        } else if config.lowpower.audioSafeMode && audioNeedsScan(config: config) {
            scan(config: config, consoleUser: consoleUser)   // audio just started: don't wait for the next scan
        }
    }

    /// Between scans: refreshes the audio detection and says whether a protected process is still
    /// demoted (or detection just failed), in which case a full scan restores it — scan() records
    /// inherited children first, so nothing a restored parent spawned is lost.
    private func audioNeedsScan(config: Config) -> Bool {
        let procs = Dictionary(ProcessScanner.list().map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let hadFailSafe = audio.failSafe != nil
        audio.update(AudioProtect.detect(), scope: config.lowpower.audioProtectScope,
                     graceSeconds: config.lowpower.audioGraceSeconds, procs: procs, now: Date().timeIntervalSince1970, log: log)
        if (audio.failSafe != nil) != hadFailSafe { return true }
        return audio.entries.contains { e in procs[e.pid].map { $0.startSec == e.startSec && $0.extDarwinBG } ?? false }
    }

    /// Undo everything (process priorities incl. inherited children + macOS Low Power Mode), delete the change record.
    /// Idempotent and safe to call when nothing was applied. Logs what it restored.
    func restoreAll(reason: String) {
        restore(reason: reason)
    }

    /// Daemon startup: undo leftovers recorded on disk by a previous run that did not exit cleanly.
    func restoreLeftoversAtStartup() {
        guard let leftover = ChangeRecord.load(path: recordPath) else { return }
        if !leftover.isEmpty {
            log.warn("found a change record from a previous run (\(leftover.procs.count) processes"
                     + "\(leftover.lpmBattery != nil || leftover.lpmAC != nil ? " + Low Power Mode" : "")); restoring it")
        }
        restore(reason: "leftovers from a previous run")
    }

    func snapshot() -> LowPowerSnapshot {
        if ProcessInfo.processInfo.systemUptime - (liveLPM?.at ?? -.infinity) >= 30 { refreshLiveLPM() }
        var s = LowPowerSnapshot()
        s.active = active
        s.trigger = active ? trigger : nil
        s.throttledCount = record.procs.count
        s.macosLowPowerBattery = liveLPM?.battery
        s.macosLowPowerAC = liveLPM?.ac
        s.originalBattery = record.lpmBattery
        s.originalAC = record.lpmAC
        s.frontmostApp = frontmostName
        s.lastScanAt = lastScanAt
        s.note = note
        if active && !audio.entries.isEmpty {
            s.audioProtected = audio.entries.map { "\($0.pid) \(ProcessScanner.info($0.pid)?.name ?? "?") (\($0.reason))" }
        }
        return s
    }

    // MARK: - Activate

    /// macOS Low Power Mode on for battery (`pmset -b`) and AC (`pmset -c`: `-b` alone has no
    /// effect while on AC, the heat case). Each original is recorded before it is changed.
    private func applyLowPowerMode() {
        let before = PowerSettings.lowPowerModes()
        var next = record
        var changing: [(name: String, flag: String, was: Int)] = []
        for (name, flag, value) in [("battery", "-b", before.battery), ("ac", "-c", before.ac)] {
            guard let v = value else {
                log.warn("Low Power Mode on \(name): current value unreadable; leaving it unchanged")
                continue
            }
            if v == 1 { continue }
            if name == "battery" { next.lpmBattery = next.lpmBattery ?? v } else { next.lpmAC = next.lpmAC ?? v }
            changing.append((name, flag, v))
        }
        if changing.isEmpty { return }
        guard next.save(path: recordPath, durable: true) else {
            log.error("cannot write the change record \(recordPath); leaving Low Power Mode unchanged")
            return
        }
        record = next
        for c in changing {
            let r = Shell.run("/usr/bin/pmset", [c.flag, "lowpowermode", "1"], timeout: 10)
            if !r.ok { log.error("pmset \(c.flag) lowpowermode 1 failed: \(Self.detail(r))") }
        }
        let after = refreshLiveLPM()
        for c in changing {
            let now = c.name == "battery" ? after.battery : after.ac
            let orig = (c.name == "battery" ? record.lpmBattery : record.lpmAC) ?? c.was
            if now == 1 {
                log.info("Low Power Mode on \(c.name): \(c.was) → 1 (original \(orig) recorded)")
            } else {
                log.error("Low Power Mode on \(c.name): still \(now.map(String.init) ?? "unknown") after pmset "
                          + "(original \(orig) recorded)")
            }
        }
    }

    // MARK: - Scan

    /// One process scan. `procs` is every process unless a test passes a subset.
    func scan(config: Config, consoleUser: ConsoleUser?, procs given: [ProcInfo]? = nil) {
        lastScanUptime = ProcessInfo.processInfo.systemUptime
        let nowEpoch = Date().timeIntervalSince1970
        lastScanAt = nowEpoch
        let since = activeSince ?? record.since ?? UInt64(nowEpoch)
        activeSince = since
        let procs = given ?? ProcessScanner.list()
        guard !procs.isEmpty else {
            log.warn("process scan: cannot list processes")
            return
        }

        // Drop entries whose process is gone (looked up directly: pid missing or reused).
        var live: [Int32: ProcInfo] = [:]
        var kept: [ChangeRecord.Proc] = []
        for e in record.procs {
            if let p = ProcessScanner.info(e.pid), p.startSec == e.startSec {
                live[p.pid] = p
                kept.append(e)
            }
        }
        // Dropping dead entries alone is not worth a write: a stale entry never matches (pid + start).
        var dirty = false
        record.procs = kept

        // Children that inherited our darwin-bg (spawned after activation by a throttled parent), and
        // such children already reparented to launchd (double-forking daemons, e.g. a tmux server).
        func inheritedFromUs(_ p: ProcInfo) -> Bool {
            if live[p.ppid] != nil { return p.startSec >= since }
            return Self.isOrphanOfOurs(p, since: since, consoleUID: consoleUser?.uid)
        }
        var inherited = 0
        var grew = true
        while grew {
            grew = false
            for p in procs where p.extDarwinBG && !p.exiting && live[p.pid] == nil && inheritedFromUs(p) {
                record.procs.append(ChangeRecord.Proc(p, inherited: true))
                live[p.pid] = p
                inherited += 1
                grew = true
            }
        }
        dirty = dirty || inherited > 0

        // Protected set for this scan.
        let protected = ProcessScanner.protectedNames(config.lowpower.protected)
        var front: FrontmostApp?
        if protected.frontmost, let user = consoleUser {
            front = ProcessScanner.frontmostApp(uid: user.uid)
            if front == nil && !frontmostUnknown {
                log.warn("cannot determine the frontmost app; throttling nothing new until it can be")
            }
            frontmostUnknown = front == nil
        } else {
            frontmostUnknown = false
        }
        frontmostName = front.flatMap { $0.name ?? ProcessScanner.info($0.pid)?.name }

        // Audio protection: who is playing right now (plus the grace period). Detection failure =
        // fail safe: nothing new is demoted and everything is restored until it works again.
        let byPID = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        if config.lowpower.audioSafeMode {
            audio.update(AudioProtect.detect(), scope: config.lowpower.audioProtectScope,
                         graceSeconds: config.lowpower.audioGraceSeconds, procs: byPID, now: nowEpoch, log: log)
        } else if !audio.entries.isEmpty || audio.failSafe != nil {
            audio.releaseAll(reason: "audio_safe_mode off", procs: byPID, log: log)
        }
        let audioFailSafe = config.lowpower.audioSafeMode && audio.failSafe != nil

        func shouldThrottle(_ p: ProcInfo) -> Bool {
            guard let user = consoleUser, !audioFailSafe else { return false }
            return ProcessScanner.isEligible(p, consoleUID: user.uid)
                && !ProcessScanner.isProtected(p, names: protected.names, frontmost: front)
                && !audio.isProtected(p)
        }

        // Restore recorded processes that are protected now (e.g. became frontmost) or not eligible
        // (e.g. an inherited system helper). Frontmost unknown → name-protected ones only.
        var restored: [String] = []
        kept = []
        for e in record.procs {
            guard let p = live[e.pid], !p.exiting, !shouldThrottle(p) else {
                kept.append(e)
                continue
            }
            if !p.extDarwinBG {                      // already back to normal
                dirty = true
                continue
            }
            switch ProcessScanner.setBackground(p, on: false) {
            case .ok:
                restored.append(p.name)
                dirty = true
                if audio.isProtected(p) {
                    log.info("audio protection: restored pid \(p.pid) \(p.name) to normal priority "
                        + "(\(audio.entries.first { $0.pid == p.pid }?.reason ?? "playing audio"))")
                }
            case .exited:
                dirty = true
            case .failed(let why):
                log.warn("could not restore \(p.name) (pid \(p.pid)): \(why)")
                kept.append(e)
            }
        }
        record.procs = kept

        // Throttle new eligible processes; needs the console user and, if listed, the frontmost app.
        var throttled: [String] = []
        var failed = 0
        var recordFailed = false
        if consoleUser != nil && !frontmostUnknown {
            let candidates = procs.filter {
                !$0.extDarwinBG && live[$0.pid] == nil && !refused.contains("\($0.pid)/\($0.startSec)") && shouldThrottle($0)
            }
            if !candidates.isEmpty {
                var next = record
                next.procs += candidates.map { ChangeRecord.Proc($0, inherited: false) }
                if next.save(path: recordPath) {                  // write-ahead
                    record = next
                    dirty = false
                    var undone = Set<Int32>()
                    for p in candidates {
                        switch ProcessScanner.setBackground(p, on: true) {
                        case .ok:
                            throttled.append(p.name)
                        case .exited:
                            undone.insert(p.pid)
                        case .failed(let why):
                            undone.insert(p.pid)
                            refused.insert("\(p.pid)/\(p.startSec)")
                            failed += 1
                            log.warn("could not throttle \(p.name) (pid \(p.pid)): \(why)")
                        }
                    }
                    if !undone.isEmpty {
                        record.procs.removeAll { !$0.inherited && undone.contains($0.pid) }
                        dirty = true
                    }
                } else {
                    log.error("cannot write the change record \(recordPath); throttling nothing")
                    recordFailed = true
                }
            }
        }
        if dirty && !record.save(path: recordPath) { log.error("cannot write the change record \(recordPath)") }

        note = recordFailed ? "cannot write the change record: throttling nothing new"
            : consoleUser == nil ? "no console user: nothing throttled"
            : frontmostUnknown ? "frontmost app unknown: throttling nothing new"
            : audioFailSafe ? "audio detection unusable (\(audio.failSafe ?? "")): everything restored, nothing throttled" : nil
        var parts: [String] = []
        if !throttled.isEmpty { parts.append("throttled \(throttled.count)\(Self.nameList(throttled))") }
        if !restored.isEmpty { parts.append("restored \(restored.count)\(Self.nameList(restored))") }
        if inherited > 0 { parts.append("inherited \(inherited)") }
        if failed > 0 { parts.append("failed \(failed)") }
        if !parts.isEmpty {
            log.info("extreme low power: " + parts.joined(separator: ", ") + " (now \(record.procs.count) in background)")
        }
    }

    // MARK: - Restore

    /// Undo everything in the record file (written before every change) plus anything only in
    /// memory. Whatever cannot be undone stays recorded and is retried later.
    private func restore(reason: String) {
        lastRestoreUptime = ProcessInfo.processInfo.systemUptime
        let wasActive = active
        let since = activeSince ?? record.since
        active = false
        activeSince = nil
        trigger = nil
        audio.releaseAll(reason: reason, procs: [:], log: log)
        frontmostName = nil
        frontmostUnknown = false
        refused = []
        var rec = ChangeRecord.load(path: recordPath) ?? ChangeRecord()
        rec.lpmBattery = rec.lpmBattery ?? record.lpmBattery
        rec.lpmAC = rec.lpmAC ?? record.lpmAC
        for p in record.procs where !rec.procs.contains(where: { $0.pid == p.pid && $0.startSec == p.startSec }) {
            rec.procs.append(p)
        }
        // Orphans that inherited our policy since the last scan (or that no scan saw).
        let start = since ?? rec.since
        if let start, let uid = Console.currentUser()?.uid {
            for p in ProcessScanner.list() where Self.isOrphanOfOurs(p, since: start, consoleUID: uid)
                && !rec.procs.contains(where: { $0.pid == p.pid && $0.startSec == p.startSec }) {
                rec.procs.append(ChangeRecord.Proc(p, inherited: true))
            }
        }
        if rec.isEmpty {
            ChangeRecord.remove(path: recordPath)
            record = ChangeRecord()
            note = nil
            if wasActive { log.info("extreme low power mode OFF (\(reason)): nothing to restore") }
            return
        }
        let procs = restoreProcesses(rec.procs, since: start)
        let lpm = restoreLowPowerMode(rec)
        var pending = ChangeRecord()
        pending.procs = procs.failed
        pending.lpmBattery = lpm.pendingBattery
        pending.lpmAC = lpm.pendingAC
        if !pending.isEmpty { pending.since = start }         // retries still know which children were ours
        record = pending
        let summary = (["processes restored: \(procs.restored) (+\(procs.children) inherited children)"] + lpm.done)
            .joined(separator: ", ")
        if pending.isEmpty {
            if !ChangeRecord.remove(path: recordPath) { log.error("cannot delete the change record \(recordPath)") }
            note = nil
            log.info("extreme low power mode OFF (\(reason)): \(summary)")
        } else {
            if !pending.save(path: recordPath) { log.error("cannot write the change record \(recordPath)") }
            note = "restore incomplete; retrying"
            log.warn("extreme low power mode OFF (\(reason)): \(summary); NOT restored yet: \(pending.procs.count) "
                     + "processes\(pending.lpmBattery != nil || pending.lpmAC != nil ? " + Low Power Mode" : ""); will retry")
        }
    }

    /// `taskpolicy -B` for each recorded process that still exists (same pid and start time) and is
    /// still darwin-bg; then for darwin-bg children of those started since activation (inherited
    /// policy), up to 5 passes.
    private func restoreProcesses(_ entries: [ChangeRecord.Proc], since: UInt64?) -> (restored: Int, children: Int, failed: [ChangeRecord.Proc]) {
        var restored = 0, children = 0
        var failed: [ChangeRecord.Proc] = []
        var parents = Set<Int32>()
        for e in entries {
            guard let p = ProcessScanner.info(e.pid), p.startSec == e.startSec else { continue }   // gone
            parents.insert(p.pid)
            guard p.extDarwinBG else { continue }
            switch ProcessScanner.setBackground(p, on: false) {
            case .ok: restored += 1
            case .exited: break
            case .failed(let why):
                log.warn("could not restore \(p.name) (pid \(p.pid)): \(why)")
                failed.append(e)
            }
        }
        var seen = parents
        for _ in 0..<5 where !parents.isEmpty {
            let found = ProcessScanner.list().filter {
                $0.extDarwinBG && !$0.exiting && !seen.contains($0.pid) && parents.contains($0.ppid)
                    && $0.startSec >= (since ?? 0)
            }
            if found.isEmpty { break }
            for p in found {
                seen.insert(p.pid)
                parents.insert(p.pid)
                switch ProcessScanner.setBackground(p, on: false) {
                case .ok: children += 1
                case .exited: break
                case .failed(let why):
                    log.warn("could not restore inherited \(p.name) (pid \(p.pid)): \(why)")
                    failed.append(ChangeRecord.Proc(p, inherited: true))
                }
            }
        }
        return (restored, children, failed)
    }

    /// Puts the recorded Low Power Mode originals back (`pmset -b|-c lowpowermode <orig>`), verified
    /// via PowerSettings. Returns what was done and the originals still not restored.
    private func restoreLowPowerMode(_ rec: ChangeRecord) -> (done: [String], pendingBattery: Int?, pendingAC: Int?) {
        let sources = [("battery", "-b", rec.lpmBattery), ("ac", "-c", rec.lpmAC)]
        guard rec.lpmBattery != nil || rec.lpmAC != nil else { return ([], nil, nil) }
        func value(_ v: (battery: Int?, ac: Int?), _ name: String) -> Int? { name == "battery" ? v.battery : v.ac }
        let before = PowerSettings.lowPowerModes()
        for (name, flag, orig) in sources {
            guard let orig = orig, value(before, name) != orig else { continue }
            let r = Shell.run("/usr/bin/pmset", [flag, "lowpowermode", String(orig)], timeout: 10)
            if !r.ok { log.error("pmset \(flag) lowpowermode \(orig) failed: \(Self.detail(r))") }
        }
        let after = refreshLiveLPM()
        var done: [String] = []
        var pending: [String: Int] = [:]
        for (name, _, orig) in sources {
            guard let orig = orig else { continue }
            let was = value(before, name)
            if value(after, name) == orig {
                done.append(was == orig ? "Low Power Mode on \(name) already \(orig)"
                                        : "Low Power Mode on \(name) \(was.map(String.init) ?? "?") → \(orig)")
            } else {
                log.error("Low Power Mode on \(name): could not restore \(orig) "
                          + "(now \(value(after, name).map(String.init) ?? "unknown"))")
                pending[name] = orig
            }
        }
        return (done, pending["battery"], pending["ac"])
    }

    // MARK: - Helpers

    /// Reparented to launchd, externally darwin-bg, started since activation, eligible, and not an app
    /// extension or XPC service (macOS puts those in the background itself): it inherited our policy.
    static func isOrphanOfOurs(_ p: ProcInfo, since: UInt64, consoleUID: uid_t?) -> Bool {
        guard let uid = consoleUID, p.extDarwinBG, !p.exiting, p.ppid == 1, p.startSec >= since else { return false }
        return ProcessScanner.isEligible(p, consoleUID: uid) && !ProcessScanner.isAppExtensionOrXPC(p.path)
    }

    @discardableResult
    private func refreshLiveLPM() -> (battery: Int?, ac: Int?) {
        let v = PowerSettings.lowPowerModes()
        liveLPM = (v.battery, v.ac, ProcessInfo.processInfo.systemUptime)
        return v
    }

    private static func detail(_ r: ShellResult) -> String {
        r.timedOut ? "timeout" : r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// " (Slack, Code Helper, …)" — unique names, at most 5.
    private static func nameList(_ names: [String]) -> String {
        var seen = Set<String>()
        let unique = names.filter { seen.insert($0).inserted }
        if unique.isEmpty { return "" }
        return " (" + unique.prefix(5).joined(separator: ", ") + (unique.count > 5 ? ", …" : "") + ")"
    }
}

/// Pure-logic tests for extreme low power mode: no process or file is touched.
enum LowPowerSelfTests {
    static func run(_ t: TestRunner) {
        func proc(_ path: String, name: String? = nil, pid: Int32 = 4242, uid: uid_t = 501, exiting: Bool = false) -> ProcInfo {
            ProcInfo(pid: pid, ppid: 1, uid: uid, startSec: 1_789_000_000, extDarwinBG: false, exiting: exiting,
                     nice: 0, priority: 31, name: name ?? (path as NSString).lastPathComponent, path: path)
        }
        func eligible(_ p: ProcInfo) -> Bool { ProcessScanner.isEligible(p, consoleUID: 501, selfPID: 999) }

        // Eligibility: user apps and user commands yes; system, other users, ourselves no.
        let slack = "/Applications/Slack.app/Contents/MacOS/Slack"
        t.check(eligible(proc(slack)), "user app eligible")
        t.check(eligible(proc("/bin/zsh")) && eligible(proc("/usr/bin/python3")) && eligible(proc("/opt/homebrew/bin/node")),
                "/bin, /usr/bin and other user commands eligible")
        t.check(eligible(proc("/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")),
                "/System/Applications eligible")
        t.check(eligible(proc("/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari")),
                "Safari cryptex eligible")
        let never = ["", "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", "/usr/libexec/secd",
                     "/usr/sbin/cfprefsd", "/sbin/launchd",
                     "/Library/Apple/System/Library/CoreServices/XProtect.app/Contents/MacOS/XProtect",
                     "/System/Volumes/Preboot/Cryptexes/OS/System/Library/Frameworks/WebKit.framework/Versions/A/"
                        + "XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent",
                     "/System/Library/CoreServices/Applications/Wireless Diagnostics.app/Contents/MacOS/Wireless Diagnostics",
                     Paths.binary, Paths.smcHelper, Paths.menuApp + "/Contents/MacOS/BatteryTool"]
        for path in never {
            t.check(!eligible(proc(path)), "never touch \(path.isEmpty ? "empty path" : path)")
        }
        for name in ["WindowServer", "loginwindow", "kernel_task", "launchd"] {
            t.check(!eligible(proc("/Users/x/bin/\(name)", name: name)), "never touch \(name)")
        }
        t.check(!eligible(proc(slack, uid: 0)) && !eligible(proc(slack, uid: 502)), "root / other users never touched")
        t.check(!eligible(proc(slack, pid: 1)) && !eligible(proc(slack, pid: 0)), "pid <= 1 never touched")
        t.check(!eligible(proc(slack, pid: 999)), "own pid never touched")
        t.check(!eligible(proc(slack, exiting: true)), "exiting process never touched")

        // Protection: process name, executable basename, enclosing .app bundle names; case-insensitive.
        let (names, wantsFront) = ProcessScanner.protectedNames(["Finder", "Dock", "Terminal", "SLACK", "@FrontMost"])
        t.check(names == ["finder", "dock", "terminal", "slack"] && wantsFront, "protected list lowercased, @frontmost found")
        t.check(!ProcessScanner.protectedNames(["Finder"]).frontmost, "no @frontmost")
        func prot(_ p: ProcInfo, _ n: Set<String>? = nil, _ f: FrontmostApp? = nil) -> Bool {
            ProcessScanner.isProtected(p, names: n ?? names, frontmost: f)
        }
        t.check(prot(proc("/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")), "Terminal protected")
        t.check(prot(proc("/System/Applications/Utilities/Terminal.app/Contents/XPCServices/x.xpc/Contents/MacOS/helper")),
                "everything inside Terminal.app protected")
        t.check(!prot(proc("/bin/zsh")), "zsh not protected by Terminal")
        t.check(prot(proc(slack)) && prot(proc("/x/y", name: "Slack")), "name match is case-insensitive")
        t.check(prot(proc("/Users/x/bin/slack", name: "other")), "executable basename match")
        t.check(!prot(proc("/Applications/Slack Helper.app/Contents/MacOS/Slack Helper")), "no partial-name match")
        let chromeHelper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/"
            + "152.0.7977.77/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        t.check(ProcessScanner.appBundleNames(in: chromeHelper) == ["Google Chrome", "Google Chrome Helper (Renderer)"],
                "enclosing .app bundle names")
        t.check(prot(proc(chromeHelper), ["google chrome"]), "outer bundle name protects its helpers")
        t.check(prot(proc(chromeHelper, name: "Google Chrome He"), ["google chrome helper (renderer)"]),
                "inner bundle / basename match despite a truncated process name")
        t.check(!prot(proc(chromeHelper), []), "empty protected list protects nothing")
        t.check(ProcessScanner.isAppExtensionOrXPC("/A/W.appex/Contents/MacOS/W")
                && ProcessScanner.isAppExtensionOrXPC("/A/S.app/Contents/XPCServices/S.xpc/Contents/MacOS/S")
                && !ProcessScanner.isAppExtensionOrXPC(chromeHelper) && !ProcessScanner.isAppExtensionOrXPC("/opt/homebrew/bin/tmux")
                && !ProcessScanner.isAppExtensionOrXPC("/A/W.appex/Contents/Helpers/H.app/Contents/MacOS/H"),
                "app extension / XPC detection (orphans that macOS backgrounds itself)")
        var orphan = proc("/opt/homebrew/bin/tmux", pid: 5000)
        orphan.extDarwinBG = true
        t.check(LowPowerManager.isOrphanOfOurs(orphan, since: 1_789_000_000, consoleUID: 501), "orphan of ours")
        t.check(!LowPowerManager.isOrphanOfOurs(orphan, since: 1_789_000_001, consoleUID: 501), "orphan started before activation")
        var appex = proc("/Applications/X.app/Contents/PlugIns/W.appex/Contents/MacOS/W", pid: 5001)
        appex.extDarwinBG = true
        t.check(!LowPowerManager.isOrphanOfOurs(appex, since: 0, consoleUID: 501), "app extension backgrounded by macOS")
        var app = proc(slack, pid: 5002)
        app.extDarwinBG = true
        t.check(LowPowerManager.isOrphanOfOurs(app, since: 0, consoleUID: 501)
                && !LowPowerManager.isOrphanOfOurs(app, since: 0, consoleUID: nil), "orphan inside an .app bundle")

        // @frontmost: its pid and everything inside its bundle (also the symlink-resolved bundle).
        let chrome = FrontmostApp(pid: 1232, bundlePaths: ["/Applications/Google Chrome.app"])
        t.check(chrome.name == "Google Chrome", "frontmost name from bundle path")
        t.check(prot(proc("/whatever", pid: 1232), [], chrome), "frontmost pid protected")
        t.check(prot(proc(chromeHelper), [], chrome), "process inside the frontmost bundle protected")
        t.check(!prot(proc("/Applications/Google Chrome Canary.app/Contents/MacOS/x"), [], chrome)
                && !prot(proc("/Applications/Google Chrome.app.old/x"), [], chrome), "bundle containment is per path component")
        let safari = FrontmostApp(pid: 77, bundlePaths: ["/Applications/Safari.app",
                                                         "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"])
        t.check(prot(proc("/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/Extensions/"
                          + "W.appex/Contents/MacOS/W"), [], safari), "symlink-resolved frontmost bundle")

        // lsappinfo output (captured on this Mac).
        t.check(ProcessScanner.parseFront("ASN:0x0-0x1c01c:\n") == "ASN:0x0-0x1c01c:", "lsappinfo front")
        t.check(ProcessScanner.parseFront("[ NULL ]\n") == nil && ProcessScanner.parseFront("") == nil, "lsappinfo front: none")
        t.check(ProcessScanner.parseAppInfo("\"pid\"=1232\n\"LSBundlePath\"=\"/Applications/Google Chrome.app\"\n") == chrome,
                "lsappinfo pid + bundle path")
        t.check(ProcessScanner.parseAppInfo("\"pid\"=[ NULL ] \n\"LSBundlePath\"=[ NULL ] \n") == nil, "lsappinfo: app gone")

        // Change record: exact format and round-trip, incl. spaces, a tab and non-ASCII in paths.
        var rec = ChangeRecord()
        rec.lpmBattery = 0
        rec.lpmAC = 1
        rec.since = 1_789_000_000
        let code = "/Applications/Visual Studio Code - Insiders.app/Contents/MacOS/Code - Insiders"
        rec.procs = [
            .init(pid: 1254, startSec: 1_789_000_000, priority: 31, nice: 0, inherited: false, path: code),
            .init(pid: 1591, startSec: 1_789_000_123, priority: -1, nice: 5, inherited: true, path: chromeHelper),
            .init(pid: 2000, startSec: 1, priority: 4, nice: -20, inherited: false, path: "/Users/x/Café ☕/odd\tname"),
        ]
        let text = rec.serialized()
        t.check(text.hasPrefix(ChangeRecord.header + "\n"), "record header")
        t.check(text.contains("\nlpm\tbattery\t0\n") && text.contains("\nlpm\tac\t1\n") && text.contains("\nsince\t1789000000\n"),
                "record lpm and since lines")
        t.check(text.contains("\nproc\t1254\t1789000000\t31\t0\t0\t\(code)\n"), "record proc line format")
        t.check(ChangeRecord.parse(text) == rec, "record round-trip")

        // Comments, blank and malformed lines are ignored.
        let messy = "# comment\tproc\t5\t5\t5\t5\t0\t/x\n\n"
            + "proc\tabc\t1\t31\t0\t0\t/x\nproc\t123\t456\nproc\t1\t456\t31\t0\t0\t/sbin/launchd\n"
            + "proc\t123\t456\t31\t0\t2\t/x\nproc\t123\t-5\t31\t0\t0\t/x\nlpm\tbattery\tx\nlpm\tdesktop\t0\n"
            + "lpm\tac\t-1\nlpm\tac\t0\textra\nbogus line\n"
            + "proc\t321\t654\t31\t0\t1\t/Applications/My App.app/Contents/MacOS/My App\nlpm\tbattery\t0\n"
        let parsed = ChangeRecord.parse(messy)
        t.check(parsed.procs == [.init(pid: 321, startSec: 654, priority: 31, nice: 0, inherited: true,
                                       path: "/Applications/My App.app/Contents/MacOS/My App")]
                && parsed.lpmBattery == 0 && parsed.lpmAC == nil, "comments and malformed lines ignored")
        t.check(ChangeRecord.parse("").isEmpty && ChangeRecord.parse(ChangeRecord().serialized()).isEmpty, "empty record")
        var evil = ChangeRecord()
        evil.procs = [.init(pid: 50, startSec: 1, priority: 31, nice: 0, inherited: false, path: "/tmp/a\nlpm\tbattery\t1")]
        let e = ChangeRecord.parse(evil.serialized())
        t.check(e.procs.count == 1 && e.lpmBattery == nil, "a newline in a path cannot inject a record line")
    }
}
