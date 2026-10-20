import Foundation

/// Audio protection for extreme low power mode: the process(es) CoreAudio reports as playing
/// audio are never demoted, and are restored if they already were. Uses the CoreAudio process
/// object list (macOS 14.2+), read by bt_audio_output_pids. Pure decisions live in
/// `AudioProtect.decide` so they can be tested without CoreAudio.
struct AudioProtect {
    /// A protected process and why.
    struct Entry: Equatable {
        var pid: Int32
        var startSec: UInt64
        var reason: String          // "playing audio", "parent of …", "child of …", "same app as …"
        var playingUntil: Double    // epoch; grace period runs from here
        var commandLine = ""        // captured when protected, for the release log line
    }

    /// What one detection round found.
    enum Detection: Equatable {
        case playing([Int32])       // pids reported as running output (may be empty)
        case failed(String)         // CoreAudio error, or no process objects at all (fail safe)
    }

    /// The protected set, kept between scans for the grace period.
    private(set) var entries: [Entry] = []
    private(set) var failSafe: String?          // set while detection is unusable
    private var lastLoggedPlaying: Set<Int32> = []
    private var cpuSamples: [Int32: (startSec: UInt64, ns: UInt64, at: Double)] = [:]   // for "pid_active"

    /// "pid_active": a process in the playing app's bundle counts as feeding the audio at this CPU
    /// share (of one core) since the previous round — the audible tab and the GPU process, not idle tabs.
    static let activePeerCPU = 0.02

    /// Live detection via CoreAudio. `objects == 0` is treated as failure: the list always holds
    /// the daemon's own object plus the user's audio apps, so an empty list means the API is not
    /// working for this process.
    static func detect() -> Detection {
        var pids = [Int32](repeating: 0, count: 256)
        var objects: Int32 = 0
        let n = bt_audio_output_pids(&pids, Int32(pids.count), &objects)
        if n < 0 { return .failed("CoreAudio error \(n)") }
        if objects == 0 { return .failed("CoreAudio reports no process objects") }
        return .playing(Array(pids.prefix(Int(n))))
    }

    /// Expands the playing pids by scope and updates the grace timers. `procs` is the current
    /// process table (pid → info). Returns the entries to protect right now.
    mutating func update(_ detection: Detection, scope: String, graceSeconds: Int,
                         procs: [Int32: ProcInfo], now: Double, log: Logger?) {
        switch detection {
        case .failed(let why):
            if failSafe == nil {
                log?.warn("audio protection: detection unusable (\(why)); restoring every throttled process "
                    + "and demoting nothing until it works")
            }
            failSafe = why
            return
        case .playing(let playing):
            if failSafe != nil { log?.info("audio protection: detection working again") }
            failSafe = nil

            // CPU share per process since the previous round (pid reuse and first sightings give none).
            var cpuShare: [Int32: Double] = [:]
            for p in procs.values {
                if let s = cpuSamples[p.pid], s.startSec == p.startSec, now > s.at, p.cpuNs >= s.ns {
                    cpuShare[p.pid] = Double(p.cpuNs - s.ns) / 1e9 / (now - s.at)
                }
            }
            cpuSamples = procs.mapValues { ($0.startSec, $0.cpuNs, now) }

            var wanted: [Int32: String] = [:]
            for pid in playing {
                guard let p = procs[pid] else { continue }
                wanted[pid] = "playing audio"
                switch scope {
                case "pid_tree":
                    if let parent = procs[p.ppid], parent.pid > 1 { wanted[parent.pid] = wanted[parent.pid] ?? "parent of \(p.name) (\(pid))" }
                    for c in procs.values where c.ppid == pid { wanted[c.pid] = wanted[c.pid] ?? "child of \(p.name) (\(pid))" }
                case "pid_active":
                    if let bundle = ProcessScanner.appBundlePath(of: p.path) {
                        for c in procs.values where c.path.hasPrefix(bundle + "/") {
                            guard let share = cpuShare[c.pid], share >= Self.activePeerCPU else { continue }
                            wanted[c.pid] = wanted[c.pid] ?? "busy (\(Int(share * 100)) % CPU) in the same app as \(p.name) (\(pid))"
                        }
                    }
                case "bundle":
                    if let bundle = ProcessScanner.appBundlePath(of: p.path) {
                        for c in procs.values where c.path.hasPrefix(bundle + "/") {
                            wanted[c.pid] = wanted[c.pid] ?? "same app as \(p.name) (\(pid)): \(bundle)"
                        }
                    }
                default:
                    break
                }
            }

            // Refresh or add entries for everything wanted; keep others until their grace runs out.
            for (pid, reason) in wanted {
                guard let p = procs[pid] else { continue }
                if let i = entries.firstIndex(where: { $0.pid == pid && $0.startSec == p.startSec }) {
                    entries[i].playingUntil = now
                    entries[i].reason = reason
                } else {
                    let cmd = Self.commandLine(pid)
                    entries.append(Entry(pid: pid, startSec: p.startSec, reason: reason, playingUntil: now, commandLine: cmd))
                    log?.info("audio protection: PROTECT pid \(pid) \(p.name) [\(reason); scope \(scope)] \(cmd)")
                }
            }
            let grace = Double(graceSeconds)
            entries.removeAll { e in
                let gone = procs[e.pid].map { $0.startSec != e.startSec } ?? true
                let expired = now - e.playingUntil > grace
                if gone || expired {
                    log?.info("audio protection: RELEASE pid \(e.pid) \(procs[e.pid]?.name ?? "?") "
                        + "[\(gone ? "process exited" : "silent for \(graceSeconds) s"); scope \(scope)] \(e.commandLine)")
                }
                return gone || expired
            }
            let set = Set(playing)
            if set != lastLoggedPlaying {
                lastLoggedPlaying = set
                log?.info("audio protection: playing now: " + (set.isEmpty ? "nothing"
                    : set.sorted().map { "\($0) \(procs[$0]?.name ?? "?")" }.joined(separator: ", ")))
            }
        }
    }

    /// Drops every entry with a RELEASE line each (the feature or the mode was turned off).
    mutating func releaseAll(reason: String, procs: [Int32: ProcInfo], log: Logger?) {
        for e in entries {
            log?.info("audio protection: RELEASE pid \(e.pid) \(procs[e.pid]?.name ?? ProcessScanner.info(e.pid)?.name ?? "?") "
                + "[\(reason)] \(e.commandLine)")
        }
        self = AudioProtect()
    }

    /// True if `p` must not be demoted right now.
    func isProtected(_ p: ProcInfo) -> Bool {
        entries.contains { $0.pid == p.pid && $0.startSec == p.startSec }
    }

    var protectedPIDs: Set<Int32> { Set(entries.map(\.pid)) }

    /// The full command line via `ps`, for the log (best effort, truncated).
    static func commandLine(_ pid: Int32) -> String {
        let r = Shell.run("/bin/ps", ["-ww", "-o", "command=", "-p", String(pid)], timeout: 3)
        let line = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.count > 300 ? String(line.prefix(300)) + "…" : line
    }
}

extension ProcessScanner {
    /// "/A/Foo.app/Contents/MacOS/x" → "/A/Foo.app" (the outermost .app bundle), nil if none.
    static func appBundlePath(of path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let i = parts.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else { return nil }
        return parts[...i].joined(separator: "/")
    }
}

enum AudioProtectSelfTests {
    static func run(_ t: TestRunner) {
        func proc(_ pid: Int32, _ ppid: Int32, _ path: String, name: String? = nil) -> ProcInfo {
            ProcInfo(pid: pid, ppid: ppid, uid: 501, startSec: 1_000 + UInt64(pid), extDarwinBG: false, exiting: false,
                     nice: 0, priority: 31, name: name ?? (path as NSString).lastPathComponent, path: path)
        }
        let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
        let renderer = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        let procs: [Int32: ProcInfo] = [
            100: proc(100, 1, chrome), 200: proc(200, 100, helper), 300: proc(300, 100, renderer),
            301: proc(301, 100, renderer), 400: proc(400, 200, "/usr/bin/true"), 500: proc(500, 1, "/Applications/Music.app/Contents/MacOS/Music"),
        ]
        t.check(ProcessScanner.appBundlePath(of: helper) == "/Applications/Google Chrome.app", "outermost bundle path")
        t.check(ProcessScanner.appBundlePath(of: "/usr/bin/true") == nil, "no bundle path")

        var a = AudioProtect()
        a.update(.playing([200]), scope: "pid", graceSeconds: 10, procs: procs, now: 0, log: nil)
        t.check(a.protectedPIDs == [200], "pid scope: only the playing process")
        t.check(a.isProtected(procs[200]!) && !a.isProtected(procs[300]!) && !a.isProtected(procs[100]!),
                "pid scope: renderers and the browser stay demotable")
        a.update(.playing([]), scope: "pid", graceSeconds: 10, procs: procs, now: 5, log: nil)
        t.check(a.protectedPIDs == [200], "grace: still protected 5 s after audio stopped")
        a.update(.playing([]), scope: "pid", graceSeconds: 10, procs: procs, now: 10.5, log: nil)
        t.check(a.protectedPIDs.isEmpty, "grace: released after audio_grace_seconds")
        a.update(.playing([200]), scope: "pid", graceSeconds: 10, procs: procs, now: 20, log: nil)
        a.update(.playing([200]), scope: "pid", graceSeconds: 10, procs: procs, now: 40, log: nil)
        a.update(.playing([]), scope: "pid", graceSeconds: 10, procs: procs, now: 45, log: nil)
        t.check(a.protectedPIDs == [200], "grace: counted from the last time it was playing")

        var tree = AudioProtect()
        tree.update(.playing([200]), scope: "pid_tree", graceSeconds: 10, procs: procs, now: 0, log: nil)
        t.check(tree.protectedPIDs == [100, 200, 400], "pid_tree: parent and direct children, not siblings")

        var bundle = AudioProtect()
        bundle.update(.playing([200]), scope: "bundle", graceSeconds: 10, procs: procs, now: 0, log: nil)
        t.check(bundle.protectedPIDs == [100, 200, 300, 301], "bundle: every process inside the .app")

        // pid_active: busy processes in the playing app's bundle, from the CPU time between rounds.
        var cpu = procs
        func burn(_ pid: Int32, _ seconds: Double) { cpu[pid]!.cpuNs += UInt64(seconds * 1e9) }
        var active = AudioProtect()
        active.update(.playing([200]), scope: "pid_active", graceSeconds: 10, procs: cpu, now: 0, log: nil)
        t.check(active.protectedPIDs == [200], "pid_active: no CPU sample yet → only the playing process")
        burn(300, 2.5); burn(301, 0.01); burn(100, 0.05); burn(500, 5)   // 50 %, 0.2 %, 1 %, 100 % over 5 s
        active.update(.playing([200]), scope: "pid_active", graceSeconds: 10, procs: cpu, now: 5, log: nil)
        t.check(active.protectedPIDs == [200, 300], "pid_active: busy renderer yes; idle tab, quiet browser, other app no")
        active.update(.playing([]), scope: "pid_active", graceSeconds: 10, procs: cpu, now: 10, log: nil)
        t.check(active.protectedPIDs == [200, 300], "pid_active: busy peer kept for the grace period")
        burn(300, 2.5)
        active.update(.playing([]), scope: "pid_active", graceSeconds: 10, procs: cpu, now: 16, log: nil)
        t.check(active.protectedPIDs.isEmpty, "pid_active: busy but silent app → released after grace")
        var reusedCPU = cpu
        reusedCPU[301] = proc(301, 100, renderer)
        reusedCPU[301]!.startSec = 99
        reusedCPU[301]!.cpuNs = cpu[301]!.cpuNs + 10_000_000_000
        active.update(.playing([200]), scope: "pid_active", graceSeconds: 10, procs: reusedCPU, now: 21, log: nil)
        t.check(!active.protectedPIDs.contains(301), "pid_active: a reused pid gets no CPU share")

        var gone = AudioProtect()
        gone.update(.playing([500]), scope: "pid", graceSeconds: 10, procs: procs, now: 0, log: nil)
        var reused = procs
        reused[500] = proc(500, 1, "/usr/bin/other")
        reused[500]!.startSec = 99
        gone.update(.playing([]), scope: "pid", graceSeconds: 10, procs: reused, now: 1, log: nil)
        t.check(gone.protectedPIDs.isEmpty, "a reused pid is not protected")

        var fail = AudioProtect()
        fail.update(.playing([200]), scope: "pid", graceSeconds: 10, procs: procs, now: 0, log: nil)
        fail.update(.failed("CoreAudio error -1"), scope: "pid", graceSeconds: 10, procs: procs, now: 1, log: nil)
        t.check(fail.failSafe != nil && fail.protectedPIDs == [200], "fail safe: flagged, earlier entries kept")
        fail.update(.playing([]), scope: "pid", graceSeconds: 10, procs: procs, now: 2, log: nil)
        t.check(fail.failSafe == nil, "fail safe clears when detection works again")

        var unknown = AudioProtect()
        unknown.update(.playing([999]), scope: "pid", graceSeconds: 10, procs: procs, now: 0, log: nil)
        t.check(unknown.protectedPIDs.isEmpty, "a pid not in the process table is ignored")
        t.check(Config().lowpower.audioSafeMode && Config().lowpower.audioProtectScope == "pid_active"
                && Config().lowpower.audioGraceSeconds == 10, "defaults: on, pid_active, 10 s")
        var c = Config()
        c.lowpower.audioProtectScope = "Whole-App"
        c.lowpower.audioGraceSeconds = -5
        let (v, notes) = c.validated()
        t.check(v.lowpower.audioProtectScope == "pid_active" && v.lowpower.audioGraceSeconds == 0 && notes.count == 2,
                "validation: unknown scope → pid_active, grace clamped")
    }
}
