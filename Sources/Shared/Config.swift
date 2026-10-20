import Foundation

/// User configuration, stored as JSON at Paths.configFile. The file is
/// admin-writable so the CLI and menu bar app can change it without sudo; the
/// root daemon therefore treats it as untrusted input: every value is clamped by
/// `validated()` and nothing in it is ever used as a path or command.
struct Config: Codable, Equatable {
    /// Bumped by every CLI write; the daemon echoes the revision it applied in status.json.
    var revision = 0
    /// Charge management (charge limit + heat guard + duty cycle). Off = always allow charging.
    var enabled = true
    /// Master pause: suspends ALL behaviour and restores normal charging / power settings.
    var paused = false
    var chargeLimit = ChargeLimit()
    var heatGuard = HeatGuard()
    var dutyCycle = DutyCycle()
    var lowpower = LowPower()
    var pollIntervalSeconds = 5
    /// Bumped by `battery-tool probe`; the daemon runs an active SMC key probe when it changes.
    var probeRequest = 0

    /// Charging resumes / extreme LPM auto-trigger releases this many °C below the limit.
    static let heatHysteresisC = 3.0
    static let autoTriggerHysteresisC = 3.0
    /// Special entry in `lowpower.protected` that stands for the frontmost app.
    static let frontmostToken = "@frontmost"

    struct ChargeLimit: Codable, Equatable {
        var maxPercent = 80
        var resumePercent = 75
    }

    struct HeatGuard: Codable, Equatable {
        var limitC = 35.0
        var resumeC: Double { limitC - Config.heatHysteresisC }
    }

    struct DutyCycle: Codable, Equatable {
        var enabled = false
        var warmC = 32.0
        var onSeconds = 30
        var offSeconds = 60
    }

    struct LowPower: Codable, Equatable {
        /// Manual extreme low power mode switch.
        var enabled = false
        var autoTrigger = AutoTrigger()
        /// App / process names never throttled (case-insensitive), plus "@frontmost".
        var protected = ["Finder", "Dock", "Terminal", Config.frontmostToken]
        var scanIntervalSeconds = 5
        /// Audio protection: processes CoreAudio reports as playing are never demoted.
        var audioSafeMode = true
        /// "pid" (only the playing process), "pid_active" (+ busy processes in its .app),
        /// "pid_tree" (+ its parent and children), "bundle" (its whole .app).
        var audioProtectScope = "pid_active"
        /// How long a process stays protected after it stops playing.
        var audioGraceSeconds = 10

        struct AutoTrigger: Codable, Equatable {
            var enabled = false
            var tempC = 40.0
            var releaseC: Double { tempC - Config.autoTriggerHysteresisC }
        }
    }

    enum CodingKeys: String, CodingKey {
        case revision, enabled, paused
        case chargeLimit = "charge_limit", heatGuard = "heat_guard", dutyCycle = "duty_cycle", lowpower
        case pollIntervalSeconds = "poll_interval_seconds", probeRequest = "probe_request"
    }
}

// Decoders live in extensions so the memberwise/default initialisers survive.
// Missing keys fall back to defaults so older or hand-edited files still load.
extension Config {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? d.revision
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? d.paused
        chargeLimit = try c.decodeIfPresent(ChargeLimit.self, forKey: .chargeLimit) ?? d.chargeLimit
        heatGuard = try c.decodeIfPresent(HeatGuard.self, forKey: .heatGuard) ?? d.heatGuard
        dutyCycle = try c.decodeIfPresent(DutyCycle.self, forKey: .dutyCycle) ?? d.dutyCycle
        lowpower = try c.decodeIfPresent(LowPower.self, forKey: .lowpower) ?? d.lowpower
        pollIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds) ?? d.pollIntervalSeconds
        probeRequest = try c.decodeIfPresent(Int.self, forKey: .probeRequest) ?? d.probeRequest
    }
}

extension Config.ChargeLimit {
    enum CodingKeys: String, CodingKey { case maxPercent = "max_percent", resumePercent = "resume_percent" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        maxPercent = try c.decodeIfPresent(Int.self, forKey: .maxPercent) ?? d.maxPercent
        resumePercent = try c.decodeIfPresent(Int.self, forKey: .resumePercent) ?? d.resumePercent
    }
}

extension Config.HeatGuard {
    enum CodingKeys: String, CodingKey { case limitC = "limit_c" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        limitC = try c.decodeIfPresent(Double.self, forKey: .limitC) ?? Self().limitC
    }
}

extension Config.DutyCycle {
    enum CodingKeys: String, CodingKey {
        case enabled, warmC = "warm_c", onSeconds = "on_seconds", offSeconds = "off_seconds"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        warmC = try c.decodeIfPresent(Double.self, forKey: .warmC) ?? d.warmC
        onSeconds = try c.decodeIfPresent(Int.self, forKey: .onSeconds) ?? d.onSeconds
        offSeconds = try c.decodeIfPresent(Int.self, forKey: .offSeconds) ?? d.offSeconds
    }
}

extension Config.LowPower {
    enum CodingKeys: String, CodingKey {
        case enabled, autoTrigger = "auto_trigger", protected, scanIntervalSeconds = "scan_interval_seconds"
        case audioSafeMode = "audio_safe_mode", audioProtectScope = "audio_protect_scope"
        case audioGraceSeconds = "audio_grace_seconds"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        autoTrigger = try c.decodeIfPresent(AutoTrigger.self, forKey: .autoTrigger) ?? d.autoTrigger
        protected = try c.decodeIfPresent([String].self, forKey: .protected) ?? d.protected
        scanIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .scanIntervalSeconds) ?? d.scanIntervalSeconds
        audioSafeMode = try c.decodeIfPresent(Bool.self, forKey: .audioSafeMode) ?? d.audioSafeMode
        audioProtectScope = try c.decodeIfPresent(String.self, forKey: .audioProtectScope) ?? d.audioProtectScope
        audioGraceSeconds = try c.decodeIfPresent(Int.self, forKey: .audioGraceSeconds) ?? d.audioGraceSeconds
    }
}

extension Config.LowPower.AutoTrigger {
    enum CodingKeys: String, CodingKey { case enabled, tempC = "temp_c" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        tempC = try c.decodeIfPresent(Double.self, forKey: .tempC) ?? d.tempC
    }
}

// MARK: - Settings UI

extension Config {
    /// The settings a settings window edits, copied onto `base` (the file as it is now). Runtime state
    /// that the menu and CLI change while the window is open — paused, the manual extreme LPM switch,
    /// the probe counter — stays as in `base`; the revision is bumped so the daemon reports applying it.
    /// With `since` (the values the window started from) only the fields the user changed are copied,
    /// so CLI changes made meanwhile to other fields survive too.
    func applyingEdits(onto base: Config, since original: Config? = nil) -> Config {
        var c = base
        func copy<T: Equatable>(_ k: WritableKeyPath<Config, T>) {
            if original == nil || original![keyPath: k] != self[keyPath: k] { c[keyPath: k] = self[keyPath: k] }
        }
        copy(\.enabled)
        copy(\.chargeLimit)
        copy(\.heatGuard)
        copy(\.dutyCycle)
        copy(\.lowpower.autoTrigger)
        copy(\.lowpower.protected)
        copy(\.lowpower.scanIntervalSeconds)
        copy(\.pollIntervalSeconds)
        c.revision = base.revision &+ 1
        return c
    }
}

// MARK: - Validation, load, save

enum ConfigError: Error, CustomStringConvertible {
    case invalid(String)
    case unwritable(String)

    var description: String {
        switch self {
        case .invalid(let m): return "invalid config: \(m)"
        case .unwritable(let m): return "cannot write config: \(m)"
        }
    }
}

extension Config {
    /// Ranges every value is clamped into (also used by the CLI to reject bad input).
    static let maxPercentRange = 20...100
    static let heatLimitRange = 25.0...60.0
    static let autoTriggerRange = 30.0...70.0
    static let dutySecondsRange = 5...3600
    static let intervalRange = 2...60
    static let audioScopes = ["pid", "pid_active", "pid_tree", "bundle"]
    static let audioGraceRange = 0...600
    /// The daemon rewrites status.json every poll, and readers treat it as stale after 20 s.
    static let pollRange = 2...10

    /// A copy with every value forced into its safe range, plus notes on what changed.
    func validated() -> (Config, [String]) {
        var c = self
        var notes: [String] = []
        func clampInt(_ v: inout Int, _ r: ClosedRange<Int>, _ name: String) {
            let n = min(max(v, r.lowerBound), r.upperBound)
            if n != v { notes.append("\(name) \(v) out of range, using \(n)"); v = n }
        }
        func clampDouble(_ v: inout Double, _ r: ClosedRange<Double>, _ name: String) {
            let n = v.isFinite ? min(max(v, r.lowerBound), r.upperBound) : r.lowerBound
            if n != v { notes.append("\(name) \(v) out of range, using \(n)"); v = n }
        }
        clampInt(&c.chargeLimit.maxPercent, Config.maxPercentRange, "charge_limit.max_percent")
        clampInt(&c.chargeLimit.resumePercent, 10...(c.chargeLimit.maxPercent - 1), "charge_limit.resume_percent")
        clampDouble(&c.heatGuard.limitC, Config.heatLimitRange, "heat_guard.limit_c")
        // Not tied to the heat limit: a warm threshold at or above it just never starts the duty cycle,
        // and a temporarily lowered heat limit must not rewrite the user's warm setting.
        clampDouble(&c.dutyCycle.warmC, 20.0...Config.heatLimitRange.upperBound, "duty_cycle.warm_c")
        clampInt(&c.dutyCycle.onSeconds, Config.dutySecondsRange, "duty_cycle.on_seconds")
        clampInt(&c.dutyCycle.offSeconds, Config.dutySecondsRange, "duty_cycle.off_seconds")
        clampDouble(&c.lowpower.autoTrigger.tempC, Config.autoTriggerRange, "lowpower.auto_trigger.temp_c")
        clampInt(&c.lowpower.scanIntervalSeconds, Config.intervalRange, "lowpower.scan_interval_seconds")
        clampInt(&c.lowpower.audioGraceSeconds, Config.audioGraceRange, "lowpower.audio_grace_seconds")
        let scope = c.lowpower.audioProtectScope.lowercased()
        if !Config.audioScopes.contains(scope) {
            notes.append("lowpower.audio_protect_scope \"\(c.lowpower.audioProtectScope)\" unknown, using \"pid_active\"")
            c.lowpower.audioProtectScope = "pid_active"
        } else {
            c.lowpower.audioProtectScope = scope
        }
        clampInt(&c.pollIntervalSeconds, Config.pollRange, "poll_interval_seconds")
        let cleaned = c.lowpower.protected
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 128 }
        if cleaned.count != c.lowpower.protected.count { notes.append("dropped empty/oversized protected entries") }
        c.lowpower.protected = Array(cleaned.prefix(200))
        return (c, notes)
    }

    /// Missing file → defaults. Unparseable file → throws (the daemon keeps its last good config).
    static func load(path: String = Paths.configFile) throws -> Config {
        guard let data = FileManager.default.contents(atPath: path) else { return Config() }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            throw ConfigError.invalid("\(path): \(error)")
        }
    }

    func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try enc.encode(self)
        data.append(0x0A)
        return data
    }

    /// Atomic replace (temp file in the same directory + rename), mode 0664.
    func save(path: String = Paths.configFile) throws {
        let dir = (path as NSString).deletingLastPathComponent
        let tmp = "\(dir)/.config.json.\(getpid()).tmp"
        do {
            let data = try encoded()
            unlink(tmp)
            guard FileManager.default.createFile(atPath: tmp, contents: data,
                                                 attributes: [.posixPermissions: 0o664]) else {
                throw ConfigError.unwritable("\(dir): \(String(cString: strerror(errno)))")
            }
            chmod(tmp, 0o664)
            if rename(tmp, path) != 0 {
                let msg = String(cString: strerror(errno))
                unlink(tmp)
                throw ConfigError.unwritable("\(path): \(msg)")
            }
        } catch let e as ConfigError {
            throw e
        } catch {
            unlink(tmp)
            throw ConfigError.unwritable("\(error)")
        }
    }
}
