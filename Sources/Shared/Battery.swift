import Foundation

/// One reading of the battery, taken from `ioreg -rn AppleSmartBattery` (as a
/// plist via -a) and `pmset -g batt`. ioreg refreshes every ~30–60 s.
struct BatteryReading: Codable, Equatable {
    var percent: Int                 // pmset value if available (matches the macOS UI), else ioreg
    var temperatureC: Double         // ioreg "Temperature" is hundredths of °C
    var isCharging: Bool             // ioreg "IsCharging"
    var externalConnected: Bool      // ioreg "ExternalConnected" (charger attached)
    var fullyCharged: Bool
    var notChargingReason: UInt64?   // ioreg ChargerData.NotChargingReason (bit 55 = SMC inhibit on M1 Pro/macOS 26)
    var ioregPercent: Int?
    var pmsetPercent: Int?
    var pmsetState: String?          // e.g. "charging", "discharging", "AC attached; not charging", "charged"
    var pmsetLine: String?
    var powerSource: String?         // "AC Power" | "Battery Power"
    var ioregUpdateTime: Int?

    enum CodingKeys: String, CodingKey {
        case percent, temperatureC = "temperature_c", isCharging = "is_charging"
        case externalConnected = "external_connected", fullyCharged = "fully_charged"
        case notChargingReason = "not_charging_reason", ioregPercent = "ioreg_percent"
        case pmsetPercent = "pmset_percent", pmsetState = "pmset_state", pmsetLine = "pmset_line"
        case powerSource = "power_source", ioregUpdateTime = "ioreg_update_time"
    }

    /// pmset says the battery is not taking charge while on AC.
    var pmsetSaysNotCharging: Bool { pmsetState?.contains("not charging") ?? false }
}

enum BatteryError: Error, CustomStringConvertible {
    case ioregFailed(String)
    case missingField(String)
    case implausible(String)

    var description: String {
        switch self {
        case .ioregFailed(let m): return "ioreg failed: \(m)"
        case .missingField(let m): return "ioreg is missing \(m)"
        case .implausible(let m): return "implausible battery value: \(m)"
        }
    }
}

enum Battery {
    /// Throws when the battery cannot be read or the values are implausible;
    /// callers must then fail safe (allow charging).
    static func read() throws -> BatteryReading {
        let io = Shell.run("/usr/sbin/ioreg", ["-a", "-r", "-n", "AppleSmartBattery"], timeout: 5)
        guard io.ok else { throw BatteryError.ioregFailed(io.timedOut ? "timeout" : io.stderr) }
        let dict = try parseIoreg(Data(io.stdout.utf8))
        let pm = Shell.run("/usr/bin/pmset", ["-g", "batt"], timeout: 5)
        return try reading(fromIoreg: dict, pmsetOutput: pm.ok ? pm.stdout : nil)
    }

    static func parseIoreg(_ data: Data) throws -> [String: Any] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
            throw BatteryError.ioregFailed("unparseable output")
        }
        if let arr = plist as? [[String: Any]], let first = arr.first { return first }
        if let dict = plist as? [String: Any] { return dict }
        throw BatteryError.ioregFailed("no AppleSmartBattery entry")
    }

    static func reading(fromIoreg d: [String: Any], pmsetOutput: String?) throws -> BatteryReading {
        func int(_ k: String) -> Int? { (d[k] as? NSNumber)?.intValue }
        func bool(_ k: String) -> Bool? { (d[k] as? NSNumber)?.boolValue }
        guard let rawTemp = int("Temperature") else { throw BatteryError.missingField("Temperature") }
        guard let cur = int("CurrentCapacity") else { throw BatteryError.missingField("CurrentCapacity") }
        let maxCap = int("MaxCapacity") ?? 100
        // Apple Silicon reports CurrentCapacity as a percentage (MaxCapacity == 100).
        let ioregPercent = maxCap == 100 ? cur : (maxCap > 0 ? Int((Double(cur) * 100 / Double(maxCap)).rounded()) : cur)
        let temp = Double(rawTemp) / 100.0
        guard (-20.0...90.0).contains(temp) else { throw BatteryError.implausible("temperature \(temp) °C") }

        let pm: (percent: Int?, state: String?, line: String?, source: String?) =
            pmsetOutput.map(parsePmsetBatt) ?? (nil, nil, nil, nil)
        let percent = pm.percent ?? ioregPercent
        guard (0...100).contains(percent) else { throw BatteryError.implausible("percent \(percent)") }

        let charger = d["ChargerData"] as? [String: Any]
        return BatteryReading(
            percent: percent,
            temperatureC: temp,
            isCharging: bool("IsCharging") ?? false,
            externalConnected: bool("ExternalConnected") ?? false,
            fullyCharged: bool("FullyCharged") ?? false,
            notChargingReason: (charger?["NotChargingReason"] as? NSNumber)?.uint64Value,
            ioregPercent: ioregPercent,
            pmsetPercent: pm.percent,
            pmsetState: pm.state,
            pmsetLine: pm.line,
            powerSource: pm.source,
            ioregUpdateTime: int("UpdateTime"))
    }

    /// Parses e.g.
    ///   Now drawing from 'AC Power'
    ///    -InternalBattery-0 (id=38600803)\t49%; AC attached; not charging present: true
    static func parsePmsetBatt(_ text: String) -> (percent: Int?, state: String?, line: String?, source: String?) {
        var source: String?
        if let first = text.split(separator: "\n").first,
           let open = first.firstIndex(of: "'"),
           let close = first[first.index(after: open)...].firstIndex(of: "'") {
            source = String(first[first.index(after: open)..<close])
        }
        guard let line = text.split(separator: "\n").first(where: { $0.contains("InternalBattery") }) else {
            return (nil, nil, nil, source)
        }
        let afterTab = line.split(separator: "\t", maxSplits: 1).last.map(String.init) ?? String(line)
        var body = afterTab.replacingOccurrences(of: " present: true", with: "")
        body = body.trimmingCharacters(in: .whitespaces)
        let parts = body.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        var percent: Int?
        if let p = parts.first, p.hasSuffix("%") { percent = Int(p.dropLast()) }
        // Drop the time estimate ("1:54 remaining", "(no estimate)").
        let stateParts = parts.dropFirst().filter { !$0.isEmpty && !$0.contains("remaining") && !$0.contains("estimate") }
        let state = stateParts.isEmpty ? nil : stateParts.joined(separator: "; ")
        return (percent, state, body, source)
    }
}

enum PowerSettings {
    /// Low Power Mode per power source from `pmset -g custom` (nil if absent).
    static func lowPowerModes() -> (battery: Int?, ac: Int?) {
        let r = Shell.run("/usr/bin/pmset", ["-g", "custom"], timeout: 10)
        return r.ok ? parseLowPowerModes(r.stdout) : (nil, nil)
    }

    static func parseLowPowerModes(_ text: String) -> (battery: Int?, ac: Int?) {
        var battery: Int?, ac: Int?
        var section = ""
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix(":") { section = line; continue }
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard f.count == 2, f[0] == "lowpowermode", let v = Int(f[1]) else { continue }
            if section.hasPrefix("Battery Power") { battery = v } else if section.hasPrefix("AC Power") { ac = v }
        }
        return (battery, ac)
    }
}
