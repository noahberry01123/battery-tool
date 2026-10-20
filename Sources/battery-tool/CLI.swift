import Foundation

/// `battery-tool <command>`: every command except `daemon` and `selftest` (main.swift).
/// Settings change by rewriting the admin-writable config file; the root daemon applies
/// them and echoes the applied revision in status.json. The CLI never writes SMC keys or
/// power settings itself. Exit codes: 0 ok, 1 error, 2 usage.
enum CLI {
    private enum Failure: Error {
        case usage(String)   // exit 2
        case error(String)   // exit 1
    }

    private static let commands: [(synopsis: String, help: String)] = [
        ("status", "battery, temperature, charging state + reason, settings, daemon"),
        ("set-limit <max> [<resume>]", "stop charging at <max>% (20–100), resume at <resume>% (default max−5)"),
        ("set-temp <limit>", "heat guard: stop charging at <limit> °C (25–60), resume 3 °C lower"),
        ("enable | disable", "charge management on / off (persistent)"),
        ("pause | resume", "suspend ALL behaviour (normal charging + power settings) / resume"),
        ("lowpower on|off|status", "extreme low power mode (approximates E-core-only operation)"),
        ("lowpower auto on|off [<temp>]", "auto-enable extreme LPM at <temp> °C (30–70, default 40), off 3 °C lower"),
        ("duty-cycle on|off [--warm C] [--on S] [--off S]", "at ≥ C °C, charge in phases: S seconds on / S seconds off"),
        ("probe", "re-verify the SMC charging key (charger connected and charging)"),
        ("uninstall [--yes]", "restore normal charging + power settings and remove battery-tool"),
        ("version | help", ""),
        ("daemon | selftest", "(internal) run the daemon (launchd only) / the built-in tests"),
    ]

    private static var usage: String {
        var lines = ["usage: battery-tool <command>", ""]
        for (synopsis, help) in commands {
            if help.isEmpty {
                lines.append("  " + synopsis)
            } else if synopsis.count > 30 {
                lines.append("  " + synopsis)
                lines.append(String(repeating: " ", count: 34) + help)
            } else {
                lines.append("  " + synopsis.padding(toLength: 32, withPad: " ", startingAt: 0) + help)
            }
        }
        lines.append("")
        lines.append("Exit status: 0 ok, 1 error, 2 usage.")
        return lines.joined(separator: "\n")
    }

    private static let disclaimer = """
        Note: extreme low power mode approximates E-core-only operation: your apps run at background
        QoS (efficiency cores) and macOS Low Power Mode is turned on. macOS does not allow disabling
        the performance cores on Apple Silicon; system processes and protected apps keep full speed.

        """

    static func run(_ args: [String]) -> Int32 {
        setlinebuf(stdout)
        let cmd = args.first ?? ""
        let rest = Array(args.dropFirst())
        do {
            switch cmd {
            case "":
                fputs(usage + "\n", stderr)
                return 2
            case "help", "--help", "-h":
                print(usage)
                return 0
            case "version", "--version":
                try expect(rest, 0...0)
                print("battery-tool \(Paths.version)")
                return 0
            case "status":
                try expect(rest, 0...0)
                return status()
            case "set-limit":
                return try setLimit(rest)
            case "set-temp":
                return try setTemp(rest)
            case "enable", "disable":
                try expect(rest, 0...0)
                let c = try save(cmd) { $0.enabled = cmd == "enable" }
                print(c.enabled ? "Charge management enabled." : "Charge management disabled: charging is always allowed.")
                showResult(c)
                return 0
            case "pause", "resume":
                try expect(rest, 0...0)
                let c = try save(cmd) { $0.paused = cmd == "pause" }
                print(c.paused ? "Paused: normal charging and power settings until 'battery-tool resume'." : "Resumed.")
                showResult(c)
                return 0
            case "lowpower":
                return try lowpower(rest)
            case "duty-cycle":
                return try dutyCycle(rest)
            case "probe":
                try expect(rest, 0...0)
                return try probe()
            case "uninstall":
                return try uninstall(rest)
            default:
                throw Failure.usage("unknown command '\(cmd)'")
            }
        } catch Failure.usage(let message) {
            fputs("battery-tool: \(message)\n", stderr)
            let lines = commands.filter { $0.synopsis.split(separator: " ").contains(Substring(cmd)) }
            fputs(lines.isEmpty ? "Run 'battery-tool help' for usage.\n"
                                : lines.map { "usage: battery-tool \($0.synopsis)\n" }.joined(), stderr)
            return 2
        } catch Failure.error(let message) {
            fputs("battery-tool: \(message)\n", stderr)
            return 1
        } catch {
            fputs("battery-tool: \(error)\n", stderr)
            return 1
        }
    }

    // MARK: - status

    /// Works without the daemon: battery, pmset and SMC values are read live.
    private static func status() -> Int32 {
        let st = DaemonStatus.load()
        let daemon = st?.isFresh() == true ? st : nil
        let smc = readSMC()
        var rows: [(String, String)] = []
        var ok = true

        do {
            let b = try Battery.read()
            var line = "\(b.percent)% · "
                + (b.pmsetState ?? (b.isCharging ? "charging" : b.externalConnected ? "AC attached, not charging" : "on battery"))
            if let ma = smc?.currentMA ?? daemon?.batteryCurrentMA { line += " · \(ma > 0 ? "+" : "")\(ma) mA" }
            rows.append(("Battery", line))
            rows.append(("Temperature", "\(fmt(b.temperatureC)) °C"))
        } catch {
            rows.append(("Battery", "unreadable — \(error)"))
            ok = false
        }

        let onHold = smc?.keys.contains { key in key.bytes.contains { $0 != 0 } } ?? false
        if let d = daemon {
            rows.append(("Charging", chargingText(d.charging)))
        } else if onHold {
            rows.append(("Charging", "ON HOLD by the SMC key, but the daemon is not running"))
            if FileManager.default.fileExists(atPath: Paths.smcHelper) {
                rows.append(("Fix", "sudo \(Paths.smcHelper) enable-charging"))
            }
        } else {
            rows.append(("Charging", "not managed — daemon not running"))
        }
        rows.append(("SMC key", keyText(smc, daemon?.charging)))

        var config: Config?
        do {
            let c = try Config.load().validated().0
            config = c
            if c.paused { rows.append(("Paused", "all behaviour suspended until 'battery-tool resume'")) }
            if !c.enabled { rows.append(("Charge control", "disabled: charging always allowed ('battery-tool enable')")) }
            rows.append(("Charge limit", "\(c.chargeLimit.maxPercent)% · resumes at \(c.chargeLimit.resumePercent)%"))
            rows.append(("Heat guard", "\(fmt(c.heatGuard.limitC)) °C · resumes at \(fmt(c.heatGuard.resumeC)) °C"))
            rows.append(("Duty cycle", dutyText(c.dutyCycle, daemon?.dutyCycle)))
        } catch {
            rows.append(("Config", "unreadable — \(error)"))
            ok = false
        }
        rows.append(("Low Power Mode", lowPowerModeText(PowerSettings.lowPowerModes(), daemon?.lowpower)))
        rows.append(("Extreme LPM", extremeText(daemon?.lowpower, config)))
        rows.append(("Daemon", daemonText(st)))
        for m in daemon?.messages.suffix(3) ?? [] { rows.append(("Warning", m)) }
        printRows(rows)
        return ok ? 0 : 1
    }

    /// Read-only live SMC values (reading needs no root): the charge-inhibit keys present on
    /// this Mac (any non-zero byte = charging on hold) and the real-time current B0AC (+ = charging).
    private static func readSMC() -> (keys: [(name: String, bytes: [UInt8])], currentMA: Int?)? {
        guard bt_smc_open() == 0 else { return nil }
        defer { bt_smc_close() }
        func read(_ key: String) -> [UInt8]? {
            var buf = [UInt8](repeating: 0, count: 32)
            var size: UInt32 = 0
            guard bt_smc_read(key, &buf, UInt32(buf.count), &size) == 0 else { return nil }
            return Array(buf.prefix(Int(size)))
        }
        let keys = ["CHTE", "CH0B", "CH0C"].compactMap { k in read(k).map { (name: k, bytes: $0) } }
        let current = read("B0AC").flatMap { b in
            b.count == 2 ? Int(Int16(bitPattern: UInt16(b[0]) | UInt16(b[1]) << 8)) : nil
        }
        return (keys, current)
    }

    /// Live key value(s), plus the daemon's active key and its verification when it runs.
    private static func keyText(_ smc: (keys: [(name: String, bytes: [UInt8])], currentMA: Int?)?,
                                _ ch: ChargingSnapshot?) -> String {
        var s: String
        if let smc = smc {
            s = smc.keys.isEmpty ? "no charge-control key on this Mac"
                : smc.keys.map { "\($0.name)=\(hex($0.bytes))" }.joined(separator: " ")
                    + (smc.keys.contains { key in key.bytes.contains { $0 != 0 } } ? " (charging on hold)" : " (charging enabled)")
        } else {
            s = "SMC unreadable"
        }
        if let ch = ch {
            s += ch.key.map { " · daemon uses \($0), \(ch.keyVerified ? "verified" : "not verified yet")" }
                ?? " · daemon: no usable key (monitor-only)"
            if let detail = ch.keyDetail, !detail.isEmpty { s += " (\(detail))" }
        }
        return s
    }

    /// "on hold — heat guard: …", "allowed — paused"; just the reason if it already says "allowed".
    private static func chargingText(_ ch: ChargingSnapshot) -> String {
        let state = ch.inhibited ? "on hold" : "allowed"
        return ch.reason.localizedCaseInsensitiveContains(state) ? ch.reason : "\(state) — \(ch.reason)"
    }

    private static func dutyText(_ d: Config.DutyCycle, _ snap: DutyCycleSnapshot?) -> String {
        var s = "\(d.enabled ? "on" : "off") · \(d.onSeconds) s on / \(d.offSeconds) s off at ≥ \(fmt(d.warmC)) °C"
        if let snap = snap, snap.active, let phase = snap.phase {
            s += " · now \(phase)-phase"
            if let end = snap.phaseEndsAt { s += ", \(max(0, Int(end - Date().timeIntervalSince1970))) s left" }
        }
        return s
    }

    /// "battery off · AC on", with "(was off)" where extreme LPM changed a value.
    private static func lowPowerModeText(_ live: (battery: Int?, ac: Int?), _ lp: LowPowerSnapshot?) -> String {
        func name(_ v: Int?) -> String { v.map { $0 == 0 ? "off" : $0 == 1 ? "on" : "\($0)" } ?? "unknown" }
        func show(_ v: Int?, _ original: Int?) -> String {
            guard let o = original, o != v else { return name(v) }
            return "\(name(v)) (was \(name(o)))"
        }
        return "battery \(show(live.battery, lp?.originalBattery)) · AC \(show(live.ac, lp?.originalAC))"
    }

    /// Extreme LPM state (from the daemon; nil = not running) plus the auto-trigger setting.
    private static func extremeText(_ lp: LowPowerSnapshot?, _ c: Config?) -> String {
        var s: String
        if let lp = lp {
            s = lp.active ? "on (\(lp.trigger ?? "manual")) · \(lp.throttledCount) processes throttled" : "off"
        } else if FileManager.default.fileExists(atPath: Paths.changeRecord) {
            // A change record outlives a daemon that died while extreme LPM was applied.
            s = "changes may still be applied (restored when the daemon starts, or by 'battery-tool uninstall')"
        } else {
            s = c?.lowpower.enabled == true ? "on in config, not applied (daemon not running)" : "off"
        }
        if let a = c?.lowpower.autoTrigger {
            s += a.enabled ? " · auto on at ≥ \(fmt(a.tempC)) °C, off at ≤ \(fmt(a.releaseC)) °C" : " · auto-trigger off"
        }
        return s
    }

    private static func daemonText(_ st: DaemonStatus?) -> String {
        guard let s = st else {
            return FileManager.default.fileExists(atPath: Paths.daemonPlist) ? "not running" : "not running (not installed)"
        }
        if s.isFresh() { return "running · \(s.mode) · pid \(s.daemonPid) · updated \(ago(s.updatedAt))" }
        return "not running (\(s.mode == "stopped" ? "stopped" : "last update") \(ago(s.updatedAt)))"
    }

    // MARK: - settings

    private static func setLimit(_ a: [String]) throws -> Int32 {
        try expect(a, 1...2)
        let top = try integer(a[0], "max", Config.maxPercentRange)
        let resume = try a.count == 2 ? integer(a[1], "resume", 10...(top - 1)) : top - 5
        let c = try save("set-limit") {
            $0.chargeLimit.maxPercent = top
            $0.chargeLimit.resumePercent = resume
        }
        print("Charge limit: charging stops at \(top)% and resumes at \(resume)%.")
        showResult(c)
        return 0
    }

    private static func setTemp(_ a: [String]) throws -> Int32 {
        try expect(a, 1...1)
        let limit = try number(a[0], "limit", Config.heatLimitRange)
        let c = try save("set-temp") { c in
            if c.dutyCycle.warmC >= limit {
                print("Note: the duty-cycle warm threshold (\(fmt(c.dutyCycle.warmC)) °C) is not below the new heat limit,"
                      + " so the duty cycle cannot start until it is.")
            }
            c.heatGuard.limitC = limit
        }
        print("Heat guard: charging stops at \(fmt(c.heatGuard.limitC)) °C and resumes at \(fmt(c.heatGuard.resumeC)) °C.")
        showResult(c)
        return 0
    }

    private static func dutyCycle(_ a: [String]) throws -> Int32 {
        guard let mode = a.first, mode == "on" || mode == "off" else {
            throw Failure.usage(a.isEmpty ? "missing on|off" : "expected on or off, got '\(a[0])'")
        }
        var warm: Double?, onSeconds: Int?, offSeconds: Int?
        var i = 1
        while i < a.count {
            guard i + 1 < a.count else { throw Failure.usage("missing value after \(a[i])") }
            switch a[i] {
            case "--warm": warm = try number(a[i + 1], "--warm", 20.0...(Config.heatLimitRange.upperBound - 0.5))
            case "--on": onSeconds = try integer(a[i + 1], "--on", Config.dutySecondsRange)
            case "--off": offSeconds = try integer(a[i + 1], "--off", Config.dutySecondsRange)
            default: throw Failure.usage("unknown option '\(a[i])'")
            }
            i += 2
        }
        let c = try save("duty-cycle") { c in
            if let w = warm {
                // Same bound validated() enforces: the duty cycle must start below the heat limit.
                guard w <= c.heatGuard.limitC - 0.5 else {
                    throw Failure.usage("--warm must be below the heat limit \(fmt(c.heatGuard.limitC)) °C"
                                        + " (at most \(fmt(c.heatGuard.limitC - 0.5)))")
                }
                c.dutyCycle.warmC = w
            }
            c.dutyCycle.enabled = mode == "on"
            if let s = onSeconds { c.dutyCycle.onSeconds = s }
            if let s = offSeconds { c.dutyCycle.offSeconds = s }
        }
        let d = c.dutyCycle
        print(d.enabled ? "Duty cycle on: at ≥ \(fmt(d.warmC)) °C charging alternates \(d.onSeconds) s on / \(d.offSeconds) s off."
                        : "Duty cycle off.")
        showResult(c)
        return 0
    }

    private static func lowpower(_ a: [String]) throws -> Int32 {
        switch a.first {
        case "on", "off":
            try expect(a, 1...1)
            let on = a[0] == "on"
            if on { print(disclaimer) }
            let c = try save("lowpower") { $0.lowpower.enabled = on }
            print("Extreme low power mode: \(on ? "on" : "off").")
            if let s = applied(c) {
                printRows([("Extreme LPM", extremeText(s.lowpower, c)),
                           ("Low Power Mode", lowPowerModeText(PowerSettings.lowPowerModes(), s.lowpower))])
                if !on && s.lowpower.active {
                    print("It stays on while the temperature auto-trigger holds it; 'battery-tool lowpower auto off' disables that.")
                }
            }
            return 0
        case "status":
            try expect(a, 1...1)
            print(disclaimer)
            let st = DaemonStatus.load()
            let lp = st?.isFresh() == true ? st?.lowpower : nil
            let c = try? Config.load().validated().0
            var rows = [("Extreme LPM", extremeText(lp, c)),
                        ("Low Power Mode", lowPowerModeText(PowerSettings.lowPowerModes(), lp))]
            if let c = c {
                rows.append(("Protected", c.lowpower.protected
                    .map { $0 == Config.frontmostToken ? "the frontmost app" : $0 }.joined(separator: ", ")))
            } else {
                rows.append(("Config", "unreadable (details: 'battery-tool status')"))
            }
            if let c = c {
                let lpc = c.lowpower
                rows.append(("Audio safe mode", lpc.audioSafeMode
                    ? "on · scope \(lpc.audioProtectScope) · \(lpc.audioGraceSeconds) s grace after audio stops" : "off"))
            }
            if let lp = lp {
                if let a = lp.audioProtected, !a.isEmpty { rows.append(("Playing audio", a.joined(separator: "; "))) }
                if let app = lp.frontmostApp { rows.append(("Frontmost app", app)) }
                if let t = lp.lastScanAt { rows.append(("Last scan", ago(t))) }
                if let note = lp.note { rows.append(("Note", note)) }
            } else {
                rows.append(("Daemon", daemonText(st)))
            }
            printRows(rows)
            return 0
        case "auto":
            try expect(a, 2...3)
            guard a[1] == "on" || a[1] == "off" else { throw Failure.usage("expected 'auto on' or 'auto off', got 'auto \(a[1])'") }
            let on = a[1] == "on"
            let temp: Double? = try a.count == 3 ? number(a[2], "temp", Config.autoTriggerRange) : nil
            if on { print(disclaimer) }
            let c = try save("lowpower") {
                $0.lowpower.autoTrigger.enabled = on
                if let t = temp { $0.lowpower.autoTrigger.tempC = t }
            }
            let t = c.lowpower.autoTrigger
            print(on ? "Auto-trigger on: extreme low power mode turns on at ≥ \(fmt(t.tempC)) °C and off at ≤ \(fmt(t.releaseC)) °C."
                     : "Auto-trigger off.")
            if let s = applied(c) { printRows([("Extreme LPM", extremeText(s.lowpower, c))]) }
            return 0
        default:
            throw Failure.usage(a.isEmpty ? "missing argument" : "unknown argument '\(a[0])'")
        }
    }

    /// Load → change → revision += 1 → validated() → atomic save. Prints validation notes.
    private static func save(_ cmd: String, _ change: (inout Config) throws -> Void) throws -> Config {
        // Explain the common failures before touching anything (save() needs a writable directory).
        if access(Paths.configDir, W_OK | X_OK) != 0 {
            let err = errno
            switch err {
            case ENOENT:
                throw Failure.error("not installed (\(Paths.configDir) does not exist); nothing was changed")
            case EACCES, EPERM:
                throw Failure.error("permission denied: \(Paths.configFile) is writable by administrators only;"
                                    + " use an admin account or sudo")
            default:
                throw Failure.error("cannot write \(Paths.configDir): \(String(cString: strerror(err)))")
            }
        }
        let loaded: Config
        do {
            loaded = try Config.load()
        } catch {
            throw Failure.error("\(error)\nNothing was changed; fix or delete \(Paths.configFile) and retry.")
        }
        let (base, oldNotes) = loaded.validated()
        var c = base
        try change(&c)
        c.revision = c.revision &+ 1
        let (saved, newNotes) = c.validated()
        try saved.save()
        for note in oldNotes + newNotes { print("Note: \(note)") }
        if saved.paused && cmd != "pause" {
            print("Note: battery-tool is paused; this takes effect after 'battery-tool resume'.")
        }
        if !saved.enabled && ["set-limit", "set-temp", "duty-cycle"].contains(cmd) {
            print("Note: charge management is disabled; 'battery-tool enable' turns it on.")
        }
        return saved
    }

    /// After a save: waits ≤ 15 s for a running daemon to apply `c`; nil (with a note) otherwise.
    private static func applied(_ c: Config) -> DaemonStatus? {
        guard DaemonStatus.load()?.isFresh() == true else {
            print("Saved; will apply when the daemon runs.")
            return nil
        }
        let deadline = Date().addingTimeInterval(15)
        repeat {
            if let s = DaemonStatus.load(), s.appliedConfigRevision >= c.revision { return s }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        print("Saved, but the daemon has not applied it yet; check 'battery-tool status' in a moment.")
        return nil
    }

    /// The resulting charging and extreme LPM state once the daemon applied `c`.
    private static func showResult(_ c: Config) {
        guard let s = applied(c) else { return }
        printRows([("Charging", chargingText(s.charging)), ("Extreme LPM", extremeText(s.lowpower, c))])
    }

    // MARK: - probe

    private static func probe() throws -> Int32 {
        guard let before = DaemonStatus.load(), before.isFresh() else {
            throw Failure.error("the daemon is not running, and the probe needs it (see 'battery-tool status')")
        }
        if (try? Config.load())?.paused == true {
            throw Failure.error("currently paused; run 'battery-tool resume' first")
        }
        // Newer than any request the daemon already answered, so its previous result is never taken
        // for this one (a reset config file would otherwise reuse the number).
        let c = try save("probe") { $0.probeRequest = max($0.probeRequest, before.probe?.request ?? 0) &+ 1 }
        print("Probe requested: the daemon briefly holds charging and confirms it via ioreg/pmset (up to ~4 min).")
        let start = Date()
        var last: String?
        while Date().timeIntervalSince(start) < 300 {
            Thread.sleep(forTimeInterval: 1)
            guard let s = DaemonStatus.load(), s.isFresh(maxAge: 60) else {
                throw Failure.error("the daemon stopped updating its status; see \(Paths.logFile)")
            }
            guard let p = s.probe, p.request >= c.probeRequest else { continue }
            if p.state != "running" && p.state != "idle" {   // any final state ends the wait (SPEC §6)
                print("Probe \(p.state): \(p.detail)")
                return p.state == "verified" ? 0 : 1
            }
            if p.detail != last {
                print("[\(Int(Date().timeIntervalSince(start))) s] \(p.detail.isEmpty ? "running…" : p.detail)")
                last = p.detail
            }
        }
        throw Failure.error("no probe result after 300 s; see \(Paths.logFile)")
    }

    // MARK: - uninstall

    private static func uninstall(_ a: [String]) throws -> Int32 {
        if let bad = a.first(where: { $0 != "--yes" }) { throw Failure.usage("unknown argument '\(bad)'") }
        guard let script = [Paths.uninstallScript, Paths.menuAppUninstallScript]
            .first(where: FileManager.default.fileExists(atPath:)) else {
            throw Failure.error("no uninstall script at \(Paths.uninstallScript) or \(Paths.menuAppUninstallScript);"
                                + " battery-tool does not appear to be installed")
        }
        if a.isEmpty {
            print("This re-enables normal charging, restores Low Power Mode and process priorities,"
                  + " and removes battery-tool completely.")
            print("Continue? [y/N] ", terminator: "")
            fflush(stdout)
            let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
            guard answer == "y" || answer == "yes" else {
                print("Cancelled; nothing was changed.")
                return 1
            }
        }
        // Root may not be allowed to read the caller's folder (e.g. ~/Documents under macOS privacy rules).
        FileManager.default.changeCurrentDirectoryPath("/")
        if geteuid() == 0 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script]   // stdio inherited: the script prints its own report
            // Fixed environment, as on the osascript path: the caller's PATH (sudo keeps it on macOS),
            // BASH_ENV or SHELLOPTS must not reach a script running as root.
            p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "LANG": "C"]
            try p.run()
            p.waitUntilExit()
            return p.terminationReason == .exit ? p.terminationStatus : 1
        }
        // Same mechanism as the menu bar app. No shell is involved until `do shell script`,
        // so the path is quoted for /bin/sh and the whole command for AppleScript.
        let command = "/bin/bash \(shellQuoted(script)) 2>&1"
        let prompt = "Battery Tool needs your password to restore normal charging and uninstall."
        let source = "do shell script \(appleScriptString(command)) with prompt \(appleScriptString(prompt))"
            + " with administrator privileges without altering line endings"
        print("Asking for an administrator password…")
        let r = Shell.run("/usr/bin/osascript", ["-e", source], timeout: 3600)
        if r.ok {
            print(r.stdout.trimmingCharacters(in: .newlines))
            return 0
        }
        let failure = osascriptFailure(r.timedOut ? "timed out" : r.stderr)
        if failure.code == -128 {
            print("Uninstall cancelled; nothing was changed.")
            return 1
        }
        if !failure.message.isEmpty { print(failure.message) }
        throw Failure.error("uninstall did not complete" + (failure.code.map { " (status \($0))" } ?? ""))
    }

    /// Single-quoted for /bin/sh; embedded single quotes become '\''.
    static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A double-quoted AppleScript string literal (backslashes escaped first, then double quotes).
    static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// osascript reports a failed `do shell script` as "0:94: execution error: <output> (<status>)";
    /// a cancelled password prompt is status -128.
    static func osascriptFailure(_ stderr: String) -> (message: String, code: Int?) {
        var s = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: "execution error: ") { s = String(s[r.upperBound...]) }
        guard s.hasSuffix(")"), let open = s.range(of: "(", options: .backwards),
              let code = Int(s[open.upperBound..<s.index(before: s.endIndex)]) else { return (s, nil) }
        return (String(s[..<open.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines), code)
    }

    // MARK: - helpers

    /// Usage error unless the number of arguments after the command is within `range`.
    private static func expect(_ a: [String], _ range: ClosedRange<Int>) throws {
        if a.count < range.lowerBound { throw Failure.usage("missing argument") }
        if a.count > range.upperBound { throw Failure.usage("unexpected argument '\(a[range.upperBound])'") }
    }

    private static func integer(_ s: String, _ name: String, _ range: ClosedRange<Int>) throws -> Int {
        guard let v = Int(s), range.contains(v) else {
            throw Failure.usage("\(name) must be a whole number from \(range.lowerBound) to \(range.upperBound), got '\(s)'")
        }
        return v
    }

    private static func number(_ s: String, _ name: String, _ range: ClosedRange<Double>) throws -> Double {
        guard let v = Double(s), range.contains(v) else {
            throw Failure.usage("\(name) must be a number from \(fmt(range.lowerBound)) to \(fmt(range.upperBound)), got '\(s)'")
        }
        return v
    }

    /// Aligned "Label:  value" lines.
    private static func printRows(_ rows: [(String, String)]) {
        let width = (rows.map { $0.0.count }.max() ?? 0) + 3
        for (label, value) in rows { print((label + ":").padding(toLength: width, withPad: " ", startingAt: 0) + value) }
    }

    private static func fmt(_ v: Double) -> String { String(format: "%.1f", v) }

    private static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    private static func ago(_ t: Double) -> String {
        let s = max(0, Int(Date().timeIntervalSince1970 - t))
        return s < 120 ? "\(s) s ago" : s < 7200 ? "\(s / 60) min ago" : s < 172_800 ? "\(s / 3600) h ago" : "\(s / 86_400) days ago"
    }
}
