import Foundation

/// Written by the daemon to Paths.statusFile (0644) after every tick; read by the
/// CLI and the menu bar app. Purely informational — never drives behaviour.
struct DaemonStatus: Codable {
    var updatedAt: Double = 0                 // epoch seconds
    var daemonPid: Int32 = 0
    var version = Paths.version
    var appliedConfigRevision = 0
    /// "active" | "paused" | "disabled" | "monitor-only" | "uninstalling" | "stopped"
    var mode = "active"
    var battery: BatteryReading?
    var batteryError: String?
    var batteryCurrentMA: Int?                // real-time SMC B0AC (+ = charging)
    var charging = ChargingSnapshot()
    var dutyCycle = DutyCycleSnapshot()
    var lowpower = LowPowerSnapshot()
    var probe: ProbeSnapshot?
    var messages: [String] = []               // recent warnings, newest last (max ~10)

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at", daemonPid = "daemon_pid", version
        case appliedConfigRevision = "applied_config_revision", mode, battery
        case batteryError = "battery_error", batteryCurrentMA = "battery_current_ma"
        case charging, dutyCycle = "duty_cycle", lowpower, probe, messages
    }

    static func load(path: String = Paths.statusFile) -> DaemonStatus? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(DaemonStatus.self, from: data)
    }

    /// True if the daemon wrote the file recently and is not stopped.
    func isFresh(maxAge: Double = 20) -> Bool {
        mode != "stopped" && Date().timeIntervalSince1970 - updatedAt <= maxAge
    }
}

struct ChargingSnapshot: Codable {
    var inhibited = false                     // battery-tool is currently blocking charging
    var reason = "starting"                   // human-readable reason for the current state
    var key: String?                          // e.g. "CHTE" or "CH0B+CH0C"; nil = no usable key
    var keyVerified = false                   // effect confirmed via ioreg/pmset on this macOS build
    var keyDetail: String?
    var limitHold = false
    var heatHold = false

    enum CodingKeys: String, CodingKey {
        case inhibited, reason, key, keyVerified = "key_verified", keyDetail = "key_detail"
        case limitHold = "limit_hold", heatHold = "heat_hold"
    }
}

struct DutyCycleSnapshot: Codable {
    var active = false
    var phase: String?                        // "on" | "off"
    var phaseEndsAt: Double?

    enum CodingKeys: String, CodingKey { case active, phase, phaseEndsAt = "phase_ends_at" }
}

struct LowPowerSnapshot: Codable {
    var active = false                        // extreme low power mode currently applied
    var trigger: String?                      // "manual" | "auto"
    var throttledCount = 0                    // processes currently moved to background QoS
    var macosLowPowerBattery: Int?            // live `pmset -g custom` values
    var macosLowPowerAC: Int?
    var originalBattery: Int?                 // recorded originals (only for sources we changed)
    var originalAC: Int?
    var frontmostApp: String?
    var lastScanAt: Double?
    var note: String?
    var audioProtected: [String]?             // "pid name (reason)" currently exempt for audio

    enum CodingKeys: String, CodingKey {
        case active, trigger, throttledCount = "throttled_count"
        case macosLowPowerBattery = "macos_low_power_battery", macosLowPowerAC = "macos_low_power_ac"
        case originalBattery = "original_battery", originalAC = "original_ac"
        case frontmostApp = "frontmost_app", lastScanAt = "last_scan_at", note, audioProtected = "audio_protected"
    }
}

struct ProbeSnapshot: Codable {
    var request = 0                           // the Config.probeRequest this result answers
    var state = "idle"                        // "running" | "verified" | "failed" | "skipped"
    var detail = ""
    var finishedAt: Double?

    enum CodingKeys: String, CodingKey { case request, state, detail, finishedAt = "finished_at" }
}
