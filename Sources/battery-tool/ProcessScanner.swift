import Foundation

/// One process, from bt_proc_info (libproc).
struct ProcInfo {
    var pid: Int32
    var ppid: Int32
    var uid: uid_t                  // effective uid
    var startSec: UInt64
    var extDarwinBG: Bool           // externally placed in darwin background (taskpolicy -b)
    var exiting: Bool
    var nice: Int32
    var priority: Int32
    var name: String
    var path: String                // "" if unavailable
    var cpuNs: UInt64 = 0           // total CPU time so far
}

extension ProcInfo {
    init(_ i: bt_procinfo) {
        func str<T>(_ chars: T) -> String {
            withUnsafeBytes(of: chars) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        }
        self.init(pid: i.pid, ppid: i.ppid, uid: i.uid, startSec: i.start_sec, extDarwinBG: i.ext_darwin_bg != 0,
                  exiting: i.exiting != 0, nice: i.nice, priority: i.priority, name: str(i.name), path: str(i.path), cpuNs: i.cpu_ns)
    }
}

/// The console user's frontmost app, from lsappinfo.
struct FrontmostApp: Equatable {
    var pid: Int32
    /// LSBundlePath, plus its symlink-resolved form (/Applications/Safari.app points into a cryptex).
    var bundlePaths: [String]

    var name: String? {
        guard let b = bundlePaths.first else { return nil }
        let last = (b as NSString).lastPathComponent
        return last.lowercased().hasSuffix(".app") ? String(last.dropLast(4)) : last
    }

    func contains(path: String) -> Bool { bundlePaths.contains { path.hasPrefix($0 + "/") } }
}

/// Process enumeration, the "never touch" rules, protection matching and the
/// taskpolicy calls used by extreme low power mode.
enum ProcessScanner {
    static let neverTouchNames: Set<String> = ["WindowServer", "loginwindow", "kernel_task", "launchd"]
    /// System executables. Any other "/System/…" path is system too unless it contains
    /// "/Applications/" (/System/Applications/…, the Safari cryptex).
    static let systemPrefixes = ["/System/Library/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"]

    static func list() -> [ProcInfo] {
        var pids = [Int32](repeating: 0, count: 16384)
        let n = Int(bt_list_pids(&pids, Int32(pids.count)))
        return n > 0 ? pids.prefix(n).compactMap { info($0) } : []
    }

    static func info(_ pid: Int32) -> ProcInfo? {
        var raw = bt_procinfo()
        return bt_proc_info(pid, &raw) == 0 ? ProcInfo(raw) : nil
    }

    /// Hard rules: only the console user's own, live, non-system processes, never
    /// pid ≤ 1, ourselves or battery-tool's own executables.
    static func isEligible(_ p: ProcInfo, consoleUID: uid_t, selfPID: Int32 = getpid()) -> Bool {
        if p.uid != consoleUID || p.pid <= 1 || p.pid == selfPID || p.exiting { return false }
        let path = p.path
        if neverTouchNames.contains(p.name) || neverTouchNames.contains((path as NSString).lastPathComponent) { return false }
        if path.isEmpty || path == Paths.binary || path.hasPrefix(Paths.libDir + "/") || path.hasPrefix(Paths.menuApp + "/") {
            return false
        }
        if systemPrefixes.contains(where: { path.hasPrefix($0) }) { return false }
        return !path.hasPrefix("/System/") || path.contains("/Applications/")
    }

    /// Config protected list → lowercased names, and whether "@frontmost" is in it.
    static func protectedNames(_ list: [String]) -> (names: Set<String>, frontmost: Bool) {
        let lower = Set(list.map { $0.lowercased() })
        return (lower.subtracting([Config.frontmostToken]), lower.contains(Config.frontmostToken))
    }

    /// `names` (lowercased) matched against the process name, the executable basename and every
    /// enclosing .app bundle name; plus the frontmost app's pid and everything inside its bundle.
    static func isProtected(_ p: ProcInfo, names: Set<String>, frontmost: FrontmostApp?) -> Bool {
        if let f = frontmost, p.pid == f.pid || f.contains(path: p.path) { return true }
        if names.isEmpty { return false }
        let candidates = [p.name, (p.path as NSString).lastPathComponent] + appBundleNames(in: p.path)
        return candidates.contains { names.contains($0.lowercased()) }
    }

    /// "/A/Foo.app/Contents/B/Bar.app/Contents/MacOS/Bar" → ["Foo", "Bar"].
    static func appBundleNames(in path: String) -> [String] {
        path.split(separator: "/").dropLast().compactMap { c in
            c.count > 4 && c.lowercased().hasSuffix(".app") ? String(c.dropLast(4)) : nil
        }
    }

    /// True if the innermost bundle around the executable is an app extension or XPC service.
    static func isAppExtensionOrXPC(_ path: String) -> Bool {
        let innermost = path.split(separator: "/").dropLast().last { c in
            let l = c.lowercased()
            return l.hasSuffix(".app") || l.hasSuffix(".appex") || l.hasSuffix(".xpc")
        }
        guard let b = innermost?.lowercased() else { return false }
        return b.hasSuffix(".appex") || b.hasSuffix(".xpc")
    }

    /// The console user's frontmost app via lsappinfo, run in that user's session
    /// (`launchctl asuser` when we are root). nil if it cannot be determined.
    static func frontmostApp(uid: uid_t) -> FrontmostApp? {
        func lsappinfo(_ args: [String]) -> String? {
            let r: ShellResult
            if geteuid() == 0 {
                r = Shell.run("/bin/launchctl", ["asuser", String(uid), "/usr/bin/lsappinfo"] + args, timeout: 2)
            } else if geteuid() == uid {
                r = Shell.run("/usr/bin/lsappinfo", args, timeout: 2)   // not root (tests): our own session
            } else {
                return nil
            }
            return r.ok ? r.stdout : nil
        }
        guard let asn = lsappinfo(["front"]).flatMap(parseFront),
              let out = lsappinfo(["info", "-only", "pid", "-only", "bundlepath", asn]),
              var app = parseAppInfo(out) else { return nil }
        if let b = app.bundlePaths.first, let resolved = realpath(b, nil) {
            let s = String(cString: resolved)
            free(resolved)
            if s != b { app.bundlePaths.append(s) }
        }
        return app
    }

    /// `lsappinfo front` → "ASN:0x0-0x1c01c:"; nil for "[ NULL ]", empty or unexpected output.
    static func parseFront(_ out: String) -> String? {
        let s = out.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = s.hasPrefix("ASN:") && s.count <= 64 && s.allSatisfy { "ASN:x-0123456789abcdefABCDEF".contains($0) }
        return ok ? s : nil
    }

    /// `lsappinfo info -only pid -only bundlepath <ASN>` → `"pid"=1232` and
    /// `"LSBundlePath"="/Applications/…app"` lines; values are `[ NULL ]` for a vanished app.
    static func parseAppInfo(_ out: String) -> FrontmostApp? {
        var pid: Int32?
        var bundle: String?
        for raw in out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("\"pid\"=") {
                pid = Int32(line.dropFirst(6))
            } else if line.hasPrefix("\"LSBundlePath\"=\""), line.hasSuffix("\""), line.count > 17 {
                var b = String(line.dropFirst(16).dropLast())
                while b.count > 1 && b.hasSuffix("/") { b.removeLast() }
                if b.hasPrefix("/") && b.count > 1 { bundle = b }
            }
        }
        guard let p = pid, p > 0 else { return nil }
        return FrontmostApp(pid: p, bundlePaths: bundle.map { [$0] } ?? [])
    }

    enum Outcome: Equatable {
        case ok
        case exited
        case failed(String)
    }

    /// `taskpolicy -b -p <pid>` (on) or `-B` (off), then verified via bt_proc_info for the same
    /// process (pid and start time).
    ///
    /// The caller's `p` can be seconds old (a scan handles hundreds of processes in turn), so the
    /// identity is checked again right before acting: a pid reused in the meantime belongs to an
    /// unrelated process (possibly root's or another user's) and must not be touched. If the pid is
    /// reused during the taskpolicy call itself, a darwin-bg we just put on the new process is undone.
    static func setBackground(_ p: ProcInfo, on: Bool) -> Outcome {
        guard let before = info(p.pid), before.startSec == p.startSec, !before.exiting else { return .exited }
        let r = Shell.run("/usr/sbin/taskpolicy", [on ? "-b" : "-B", "-p", String(p.pid)], timeout: 5)
        guard let now = info(p.pid), now.startSec == p.startSec else {
            if on, let other = info(p.pid), other.extDarwinBG {
                _ = Shell.run("/usr/sbin/taskpolicy", ["-B", "-p", String(p.pid)], timeout: 5)
            }
            return .exited
        }
        if now.extDarwinBG == on { return .ok }
        let err = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(r.timedOut ? "taskpolicy timed out" : err.isEmpty ? "taskpolicy exit \(r.status)" : err)
    }
}
