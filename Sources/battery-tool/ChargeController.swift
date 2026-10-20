import Foundation

/// AppleSMC access used by ChargeController. Injectable so the self-tests can run the
/// controller against an in-memory fake; `live` goes through Sources/CSMC.
struct SMCAccess {
    var open: () -> Int32
    /// (0 | BT_SMC_KEY_NOT_FOUND | other error, size, type) of a key.
    var keyInfo: (String) -> (code: Int32, size: UInt32, type: String)
    var read: (String) -> [UInt8]?
    var write: (String, [UInt8]) -> Int32
    var emergencyAdd: (String, [UInt8]) -> Void
    var installCrashHandlers: () -> Void

    static let live = SMCAccess(
        open: { bt_smc_open() },
        keyInfo: { key in
            var size: UInt32 = 0
            var type = [CChar](repeating: 0, count: 5)
            let code = bt_smc_key_info(key, &size, &type)
            return (code, size, String(decoding: type.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        },
        read: { key in
            var buf = [UInt8](repeating: 0, count: 32)
            var size: UInt32 = 0
            guard bt_smc_read(key, &buf, UInt32(buf.count), &size) == 0 else { return nil }
            return Array(buf.prefix(Int(size)))
        },
        write: { key, bytes in bt_smc_write(key, bytes, UInt32(bytes.count)) },
        emergencyAdd: { key, bytes in _ = bt_smc_emergency_add(key, bytes, UInt32(bytes.count)) },
        installCrashHandlers: { bt_install_crash_handlers() })
}

/// Owns the charge-inhibit SMC key: detection by existence, the startup failsafe, applying the
/// policy (read → write only if different → read back), effect verification (passive window and
/// active probe) and state.json. It writes nothing but the candidates' own inhibit/enable values.
final class ChargeController {
    /// One way to inhibit charging; usable when every key exists with `size` bytes.
    struct Candidate {
        let name: String
        let keys: [String]
        let size: UInt32
        let inhibit: [UInt8]
        let enable: [UInt8]
    }

    static let candidates = [
        Candidate(name: "CHTE", keys: ["CHTE"], size: 4, inhibit: [1, 0, 0, 0], enable: [0, 0, 0, 0]),
        Candidate(name: "CH0B+CH0C", keys: ["CH0B", "CH0C"], size: 1, inhibit: [2], enable: [0]),
    ]
    /// Length of the passive verification window and of each probe stage.
    static let windowSeconds = 120.0

    /// state.json: the verification result for one key on one macOS build.
    struct KeyRecord: Codable {
        var key: String
        var osBuild: String
        var verified: Bool
        var verifiedAt: Double?
        var detail: String

        enum CodingKeys: String, CodingKey {
            case key, osBuild = "os_build", verified, verifiedAt = "verified_at", detail
        }
    }

    private enum ProbeStage { case inhibiting, resuming }

    private let smc: SMCAccess
    private let statePath: String?
    private let build: String
    private let log: Logger?
    private let report: (String) -> Void

    /// Every candidate key present with the expected size, with its "charging enabled" value.
    private(set) var existing: [(key: String, enable: [UInt8])] = []
    private var usable: [Candidate] = []
    private var failed: Set<String> = []
    private(set) var active: Candidate?
    /// Why there is no active key (monitor-only).
    private(set) var unavailable = "AppleSMC not opened"
    private(set) var keyVerified = false
    private(set) var keyDetail: String?
    private(set) var probe: ProbeSnapshot?
    /// The Config.probeRequest already answered; the daemon seeds it at startup.
    var handledProbeRequest = 0

    private var currentKeyOK = false
    /// Last state confirmed by read-back: true = inhibited, false = enabled, nil = unknown.
    private(set) var confirmed: Bool?
    private var passive: (started: Double, fastLogged: Bool)?
    private var probeStage: ProbeStage?
    private var probeSince = 0.0
    private var probeConfirmation = ""
    private var lastFailure = ""
    private var lastReported: [String: Double] = [:]

    var inhibited: Bool { confirmed == true }
    var probeRunning: Bool { probeStage != nil }

    init(smc: SMCAccess = .live, statePath: String? = Paths.stateFile, build: String = OSInfo.build,
         log: Logger?, report: @escaping (String) -> Void = { _ in }) {
        self.smc = smc
        self.statePath = statePath
        self.build = build
        self.log = log
        self.report = report
    }

    // MARK: - Startup and failsafe

    /// Startup steps 1–3: open AppleSMC; detect the candidate keys by existence + size; register
    /// their enable values for the crash path and install the crash handlers; write "charging
    /// enabled" to every one (read back, 3 attempts). No usable key → monitor-only.
    func start() {
        let r = smc.open()
        guard r == 0 else {
            unavailable = "AppleSMC could not be opened (error \(r))"
            logError("\(unavailable); monitor-only, charging is never inhibited")
            return
        }
        logInfo("AppleSMC opened")
        for c in Self.candidates {
            var complete = true
            for key in c.keys {
                guard let info = keyInfo(key) else {
                    logInfo("SMC key \(key): absent")
                    complete = false
                    continue
                }
                guard info.size == c.size else {
                    logWarn("SMC key \(key) has \(info.size) bytes (\(info.type)), expected \(c.size); not used")
                    complete = false
                    continue
                }
                logInfo("SMC key \(key): present (\(info.type), \(info.size) bytes)")
                existing.append((key, c.enable))
            }
            if complete { usable.append(c) }
        }
        if let info = keyInfo("B0AC") { currentKeyOK = info.size == 2 && info.type == "si16" }
        for k in existing { smc.emergencyAdd(k.key, k.enable) }
        smc.installCrashHandlers()
        logInfo("crash handlers installed (\(existing.count) key(s) registered for emergency re-enable)")
        enableAll("startup failsafe")
        unavailable = "no charge-inhibit SMC key found (tried \(Self.candidates.map(\.name).joined(separator: ", ")))"
        selectActive()
    }

    /// Writes "charging enabled" to every existing candidate key and reads it back (3 attempts each).
    /// Used at startup, shutdown and uninstall. True when every key verified.
    @discardableResult
    func enableAll(_ context: String) -> Bool {
        passive = nil
        guard !existing.isEmpty else {
            logInfo("\(context): no charge-inhibit SMC key present, nothing to re-enable")
            return true
        }
        var ok = true
        for k in existing {
            if writeRetrying(k.key, k.enable) {
                logInfo("\(context): \(k.key) = \(Self.hex(k.enable)) (charging enabled, read back OK)")
            } else {
                ok = false
                logError("\(context): could not set \(k.key) = \(Self.hex(k.enable)) after 3 attempts (\(lastFailure))")
            }
        }
        confirmed = ok ? false : nil
        return ok
    }

    /// Live battery current (mA, + = charging) from SMC B0AC, nil when unavailable.
    func batteryCurrentMA() -> Int? {
        guard currentKeyOK, let bytes = smc.read("B0AC") else { return nil }
        return Self.decodeCurrent(bytes)
    }

    /// B0AC is si16 LITTLE-endian on this hardware (81 0b = 2945 mA while charging).
    static func decodeCurrent(_ b: [UInt8]) -> Int? {
        guard b.count == 2 else { return nil }
        return Int(Int16(bitPattern: UInt16(b[0]) | UInt16(b[1]) << 8))
    }

    /// The stored record if it is for `key` on `build` (a verification only counts for the same build).
    static func record(from data: Data?, key: String, build: String) -> KeyRecord? {
        guard let data, let r = try? JSONDecoder().decode(KeyRecord.self, from: data),
              r.key == key, r.osBuild == build else { return nil }
        return r
    }

    // MARK: - Per tick

    /// One daemon tick: answers a new probe request, advances a running probe (normal policy is
    /// suspended meanwhile), otherwise applies the policy decision and the passive verification.
    func tick(inhibit: Bool, reason: String, paused: Bool, probeRequest: Int,
              battery: BatteryReading?, currentMA: Int?, now: Double) {
        if probeRequest != handledProbeRequest {
            let isNew = probeRequest > handledProbeRequest     // lower = the config was reset, not a request
            handledProbeRequest = probeRequest
            if isNew {
                abortProbe("superseded by probe request #\(probeRequest)", now: now)
                startProbe(probeRequest, paused: paused, policyHold: inhibit ? reason : nil,
                           battery: battery, currentMA: currentMA, now: now)
            }
        }
        if probeStage != nil {
            if paused {
                abortProbe("battery-tool was paused", now: now)
            } else if let b = battery {
                stepProbe(b, currentMA: currentMA, now: now)
            } else {
                abortProbe("battery data unreadable", now: now)
            }
            if probeStage != nil { return }
        }
        let wasInhibited = inhibited
        let ok = apply(inhibit: inhibit, reason: reason, now: now)
        stepPassive(justInhibited: ok && inhibit && !wasInhibited, battery: battery, currentMA: currentMA, now: now)
    }

    /// Drives the active key to `inhibit`: read, write only if different, read back. A value that
    /// differs from what we last confirmed was changed externally: rewrite and warn (rate-limited).
    /// A failed inhibit is answered with a best-effort enable. No key (monitor-only): never writes.
    @discardableResult
    func apply(inhibit: Bool, reason: String, now: Double) -> Bool {
        guard let c = active else { return !inhibit }
        let want = inhibit ? c.inhibit : c.enable
        var ok = true
        for key in c.keys {
            let current = smc.read(key)
            if current == want { continue }
            if confirmed == inhibit, let cur = current {
                limited("external \(key)", now: now) {
                    logWarn("\(key) was changed externally to \(Self.hex(cur)); rewriting \(Self.hex(want))")
                }
            }
            if !writeVerified(key, want) { ok = false }
        }
        if ok {
            confirmed = inhibit
            return true
        }
        limited("apply \(inhibit)", now: now) {
            logError("could not \(inhibit ? "pause" : "re-enable") charging via \(c.name) (\(lastFailure)) "
                + "for \(reason); retrying every tick")
        }
        if inhibit {
            let reverted = c.keys.map { writeVerified($0, c.enable) }.allSatisfy { $0 }
            confirmed = reverted ? false : nil
        } else {
            confirmed = nil
        }
        return false
    }

    /// Drops a running passive verification window without a verdict (e.g. before sleep).
    func cancelPassiveCheck(_ why: String) {
        guard passive != nil, let c = active else { return }
        passive = nil
        logInfo("verification of \(c.name) postponed: \(why)")
    }

    /// Passive verification: after switching to inhibit while charging, wait ≤ 120 s for ioreg AND
    /// pmset to report not charging (B0AC ≤ 50 mA is logged as the fast signal). Still charging per
    /// ioreg/pmset with B0AC > 100 mA at the end → the key failed.
    private func stepPassive(justInhibited: Bool, battery: BatteryReading?, currentMA: Int?, now: Double) {
        guard let c = active else {
            passive = nil
            return
        }
        // A duty cycle restarts the window every off-phase, so its log lines are rate-limited.
        if justInhibited, !keyVerified, let b = battery, Self.chargingObserved(b, currentMA) {
            passive = (now, false)
            limited("passive start", now: now) {
                logInfo("verifying \(c.name): waiting up to 120 s for ioreg/pmset to report not charging "
                    + "(before: \(Self.describe(b, currentMA)))")
            }
            return
        }
        guard var w = passive else { return }
        guard inhibited else {
            passive = nil
            limited("passive postponed", now: now) {
                logInfo("verification of \(c.name) postponed: charging was re-enabled before ioreg/pmset confirmed")
            }
            return
        }
        guard let b = battery else { return }
        let waited = Int(now - w.started)
        if let ma = currentMA, ma <= 50, !w.fastLogged {
            w.fastLogged = true
            limited("passive fast", now: now) {
                logInfo("\(c.name): B0AC \(ma) mA \(waited) s after pausing (fast signal: charging stopped)")
            }
        }
        if Self.confirmsInhibit(b, since: w.started) {
            passive = nil
            saveRecord(c, verified: true, detail: "verified on macOS \(build): ioreg IsCharging=No and pmset "
                + "\"\(b.pmsetState ?? "?")\" \(waited) s after pausing (B0AC \(Self.ma(currentMA)))", now: now)
            logInfo("SMC key \(c.name) VERIFIED — \(keyDetail ?? "")")
        } else if now - w.started >= Self.windowSeconds {
            passive = nil
            let state = Self.describe(b, currentMA)
            if Self.stillCharging(b, currentMA) {
                markFailed(c, "still charging \(waited) s after pausing (\(state))", now: now)
            } else {
                logWarn("could not verify \(c.name) within 120 s (\(state)); will retry at the next pause")
            }
        } else {
            passive = w
        }
    }

    /// The inhibit had no effect: re-enable charging on that key, record the failure, and fall
    /// back to the next usable candidate, else monitor-only.
    private func markFailed(_ c: Candidate, _ detail: String, now: Double) {
        for key in c.keys where !writeRetrying(key, c.enable) {
            logError("could not re-enable \(key) after its failed verification (\(lastFailure))")
        }
        failed.insert(c.name)
        confirmed = nil
        let text = "FAILED on macOS \(build): \(detail)"
        logError("SMC key \(c.name) \(text); charging re-enabled on it")
        saveRecord(c, verified: false, detail: text, now: now)
        selectActive()
        if active == nil { keyDetail = "\(c.name) \(text)" }
    }

    // MARK: - Active probe

    private func startProbe(_ request: Int, paused: Bool, policyHold: String?,
                            battery: BatteryReading?, currentMA: Int?, now: Double) {
        if !failed.isEmpty {                       // a probe re-tests keys that failed earlier in this run
            failed.removeAll()
            selectActive()
        }
        passive = nil
        probe = ProbeSnapshot(request: request, state: "running", detail: "starting", finishedAt: nil)
        var skip: String?
        if active == nil {
            skip = "no usable charge-inhibit SMC key (\(unavailable))"
        } else if paused {
            skip = "battery-tool is paused; resume it, then probe again"
        } else if let hold = policyHold {
            skip = "battery-tool is holding charging right now (\(hold)); run `battery-tool disable`, "
                + "wait until the battery charges, then probe again"
        } else if let b = battery {
            if !b.externalConnected {
                skip = "no charger connected; connect AC power and probe again"
            } else if !Self.chargingObserved(b, currentMA) {
                skip = "the battery is not charging (\(Self.describe(b, currentMA))); probe again while it charges"
            }
        } else {
            skip = "battery data unreadable"
        }
        if let s = skip {
            finishProbe("skipped", s, now: now)
            return
        }
        guard let c = active, apply(inhibit: true, reason: "probe", now: now) else {
            finishProbe("failed", "could not write the inhibit value (\(lastFailure)); charging re-enabled", now: now)
            return
        }
        probeStage = .inhibiting
        probeSince = now
        probe?.detail = "charging paused via \(c.name); waiting up to 120 s for ioreg/pmset to report not charging"
        logInfo("probe #\(request): \(probe?.detail ?? "")")
    }

    private func stepProbe(_ b: BatteryReading, currentMA: Int?, now: Double) {
        guard let c = active, let stage = probeStage else { return }
        guard now >= probeSince else {             // the 120 s bounds no longer hold
            abortProbe("the system clock was set back", now: now)
            return
        }
        let waited = Int(now - probeSince)
        let state = Self.describe(b, currentMA)
        switch stage {
        case .inhibiting:
            if !b.externalConnected {
                abortProbe("the charger was disconnected", now: now)
            } else if Self.confirmsInhibit(b, since: probeSince) {
                probeConfirmation = "ioreg IsCharging=No and pmset \"\(b.pmsetState ?? "?")\" \(waited) s after pausing "
                    + "(B0AC \(Self.ma(currentMA)))"
                saveRecord(c, verified: true, detail: "verified on macOS \(build) by probe: \(probeConfirmation)", now: now)
                apply(inhibit: false, reason: "probe: re-enabling", now: now)
                probeStage = .resuming
                probeSince = now
                probe?.detail = "confirmed: \(probeConfirmation); charging re-enabled, waiting up to 120 s for it to resume"
                logInfo("probe #\(probe?.request ?? 0): \(probe?.detail ?? "")")
            } else if now - probeSince >= Self.windowSeconds {
                apply(inhibit: false, reason: "probe: re-enabling", now: now)
                if Self.stillCharging(b, currentMA) {
                    markFailed(c, "probe: still charging \(waited) s after pausing (\(state))", now: now)
                    finishProbe("failed", "\(c.name) did not stop charging within 120 s (\(state)); charging re-enabled", now: now)
                } else {
                    saveRecord(c, verified: false, detail: "not verified on macOS \(build): no ioreg/pmset confirmation "
                        + "within 120 s of a probe (\(state))", now: now)
                    finishProbe("failed", "no ioreg/pmset confirmation within 120 s (\(state)); charging re-enabled", now: now)
                }
            }
        case .resuming:
            apply(inhibit: false, reason: "probe: re-enabling", now: now)     // retries a failed enable
            if (currentMA ?? 0) > 100 || b.isCharging || Self.pmsetCharging(b) {
                finishProbe("verified", "\(probeConfirmation); charging resumed after \(waited) s "
                    + "(B0AC \(Self.ma(currentMA)))", now: now)
            } else if !b.externalConnected {
                finishProbe("verified", "\(probeConfirmation); resume not checked: the charger was disconnected", now: now)
            } else if now - probeSince >= Self.windowSeconds {
                if c.keys.allSatisfy({ smc.read($0) == c.enable }) {
                    finishProbe("verified", "\(probeConfirmation); WARNING: charging has not resumed within 120 s although "
                        + "\(c.name) reads back enabled (\(state)); macOS may be holding the charge "
                        + "(e.g. Optimized Battery Charging)", now: now)
                } else {
                    finishProbe("failed", "\(probeConfirmation); \(c.name) does not read back enabled, "
                        + "charging may still be blocked", now: now)
                }
            }
        }
    }

    /// Ends a running probe early with charging re-enabled (pause, unreadable battery, sleep,
    /// shutdown, uninstall, a newer request).
    func abortProbe(_ why: String, now: Double) {
        guard let stage = probeStage else { return }
        apply(inhibit: false, reason: "probe aborted", now: now)
        if stage == .resuming {
            finishProbe("verified", "\(probeConfirmation); resume check cut short: \(why)", now: now)
        } else {
            finishProbe("failed", "aborted before a result: \(why); charging re-enabled (the key was not judged)", now: now)
        }
    }

    private func finishProbe(_ state: String, _ detail: String, now: Double) {
        probeStage = nil
        probe?.state = state
        probe?.detail = detail
        probe?.finishedAt = now
        let line = "probe #\(probe?.request ?? 0) \(state): \(detail)"
        if state == "verified" && !detail.contains("WARNING") { logInfo(line) } else { logWarn(line) }
    }

    // MARK: - Evidence

    /// Charging right now: B0AC > 100 mA when B0AC is available (real time; ioreg can be a minute
    /// stale), else ioreg/pmset.
    static func chargingObserved(_ b: BatteryReading, _ currentMA: Int?) -> Bool {
        if let ma = currentMA { return ma > 100 }
        return b.isCharging || pmsetCharging(b)
    }

    /// ioreg AND pmset report not charging, from an ioreg refresh after `since` (when known).
    static func confirmsInhibit(_ b: BatteryReading, since: Double) -> Bool {
        !b.isCharging && b.pmsetSaysNotCharging && (b.ioregUpdateTime.map { Double($0) > since } ?? true)
    }

    /// Conclusive evidence that an inhibit had no effect: charging per ioreg/pmset AND B0AC > 100 mA.
    static func stillCharging(_ b: BatteryReading, _ currentMA: Int?) -> Bool {
        (b.isCharging || pmsetCharging(b)) && (currentMA ?? 0) > 100
    }

    static func pmsetCharging(_ b: BatteryReading) -> Bool {
        guard let s = b.pmsetState else { return false }
        return s.hasPrefix("charging") || s.hasPrefix("finishing charge")
    }

    static func describe(_ b: BatteryReading, _ currentMA: Int?) -> String {
        "ioreg IsCharging=\(b.isCharging ? "Yes" : "No"), pmset \"\(b.pmsetState ?? "?")\", B0AC \(ma(currentMA))"
    }

    static func ma(_ v: Int?) -> String { v.map { "\($0) mA" } ?? "n/a" }

    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    // MARK: - SMC writes, state.json, logging

    /// Writes one key and reads it back. Refuses anything but a candidate key's own inhibit or
    /// enable value, so no other SMC key or value can ever be written.
    private func writeVerified(_ key: String, _ bytes: [UInt8]) -> Bool {
        guard Self.candidates.contains(where: { $0.keys.contains(key) && ($0.inhibit == bytes || $0.enable == bytes) }) else {
            lastFailure = "refused to write \(Self.hex(bytes)) to \(key)"
            logError(lastFailure)
            return false
        }
        let r = smc.write(key, bytes)
        guard r == 0 else {
            lastFailure = "\(key) write error \(r)"
            return false
        }
        let back = smc.read(key)
        guard back == bytes else {
            lastFailure = "\(key) reads back \(back.map(Self.hex) ?? "nothing") after writing \(Self.hex(bytes))"
            return false
        }
        return true
    }

    private func writeRetrying(_ key: String, _ bytes: [UInt8]) -> Bool {
        for attempt in 1...3 {
            if writeVerified(key, bytes) { return true }
            if attempt < 3 { usleep(100_000) }
        }
        return false
    }

    /// Key size/type, nil when absent. Errors other than "not found" are retried, then treated as absent.
    private func keyInfo(_ key: String) -> (size: UInt32, type: String)? {
        var code: Int32 = 0
        for attempt in 1...3 {
            let r = smc.keyInfo(key)
            if r.code == 0 { return (r.size, r.type) }
            if r.code == BT_SMC_KEY_NOT_FOUND { return nil }
            code = r.code
            if attempt < 3 { usleep(100_000) }
        }
        logError("SMC key \(key): key info failed (error \(code)); treated as absent")
        return nil
    }

    private func selectActive() {
        active = usable.first { !failed.contains($0.name) }
        keyVerified = false
        keyDetail = nil
        guard let c = active else {
            if !usable.isEmpty { unavailable = "every charge-inhibit SMC key failed verification" }
            logWarn("no usable charge-inhibit SMC key (\(unavailable)); monitor-only, charging is never inhibited")
            return
        }
        logInfo("charge-inhibit key: \(c.name) (inhibit \(Self.hex(c.inhibit)), enable \(Self.hex(c.enable)))")
        keyDetail = "not yet verified on macOS \(build)"
        if let path = statePath,
           let rec = Self.record(from: FileManager.default.contents(atPath: path), key: c.name, build: build) {
            keyVerified = rec.verified
            keyDetail = rec.detail
            logInfo("state.json: \(c.name) \(rec.verified ? "verified" : "not verified"): \(rec.detail)")
        }
    }

    private func saveRecord(_ c: Candidate, verified: Bool, detail: String, now: Double) {
        keyVerified = verified
        keyDetail = detail
        guard let path = statePath else { return }
        let rec = KeyRecord(key: c.name, osBuild: build, verified: verified, verifiedAt: verified ? now : nil, detail: detail)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(rec), Daemon.writeAtomically(data, to: path) else {
            logError("could not write \(path)")
            return
        }
    }

    private func logInfo(_ m: String) { log?.info(m) }
    private func logWarn(_ m: String) { log?.warn(m); report(m) }
    private func logError(_ m: String) { log?.error(m); report(m) }

    /// Runs `body` at most once per 5 minutes per `id`, so a persistent failure cannot flood the log.
    private func limited(_ id: String, now: Double, _ body: () -> Void) {
        if let last = lastReported[id], now >= last, now - last < 300 { return }
        lastReported[id] = now
        body()
    }
}

// MARK: - Self-tests (in-memory fake SMC; no root, touches nothing)

extension PolicySelfTests {
    /// In-memory AppleSMC: `values` holds the keys that exist.
    private final class FakeSMC {
        var values: [String: [UInt8]]
        var writes = 0
        var failWrites = false
        var reports: [String] = []

        init(_ values: [String: [UInt8]]) { self.values = values }

        var access: SMCAccess {
            SMCAccess(
                open: { 0 },
                keyInfo: { key in
                    guard let v = self.values[key] else { return (BT_SMC_KEY_NOT_FOUND, 0, "") }
                    return (0, UInt32(v.count), key == "B0AC" ? "si16" : "ui32")
                },
                read: { self.values[$0] },
                write: { key, bytes in
                    self.writes += 1
                    guard !self.failWrites, self.values[key]?.count == bytes.count else { return -1 }
                    self.values[key] = bytes
                    return 0
                },
                emergencyAdd: { _, _ in },
                installCrashHandlers: {})
        }

        func controller() -> ChargeController {
            let c = ChargeController(smc: access, statePath: nil, build: "TEST", log: nil,
                                     report: { self.reports.append($0) })
            c.start()
            return c
        }
    }

    private static func step(_ c: ChargeController, hold: Bool = false, paused: Bool = false, probe: Int = 0,
                             _ b: BatteryReading?, _ ma: Int?, at now: Double) {
        c.tick(inhibit: hold, reason: hold ? "test hold" : "test allow", paused: paused, probeRequest: probe,
               battery: b, currentMA: ma, now: now)
    }

    static func controllerTests(_ t: TestRunner) {
        let enabled: [UInt8] = [0, 0, 0, 0], inhibited: [UInt8] = [1, 0, 0, 0]
        func charging(_ updated: Int) -> BatteryReading { reading(80, 30, charging: true, pmset: "charging", updated: updated) }
        func stopped(_ updated: Int) -> BatteryReading {
            reading(80, 30, charging: false, pmset: "AC attached; not charging", updated: updated)
        }

        t.check(ChargeController.decodeCurrent([0x81, 0x0b]) == 2945, "B0AC: 81 0b = +2945 mA (little-endian)")
        t.check(ChargeController.decodeCurrent([0xff, 0xff]) == -1 && ChargeController.decodeCurrent([0x00, 0x80]) == -32768,
                "B0AC: signed 16-bit")
        t.check(ChargeController.decodeCurrent([0x01]) == nil, "B0AC: wrong size rejected")

        // Detection by existence + size; failsafe enable of every existing candidate key.
        let f1 = FakeSMC(["CHTE": inhibited, "B0AC": [0x81, 0x0b]])
        let c1 = f1.controller()
        t.check(c1.active?.name == "CHTE" && f1.values["CHTE"] == enabled && !c1.inhibited,
                "startup: CHTE detected and failsafe re-enabled")
        t.check(c1.batteryCurrentMA() == 2945 && !c1.keyVerified, "startup: B0AC read, key not yet verified")
        let f2 = FakeSMC(["CHTE": [1], "CH0B": [2], "CH0C": [2]])
        let c2 = f2.controller()
        t.check(c2.active?.name == "CH0B+CH0C" && f2.values["CH0B"] == [0] && f2.values["CH0C"] == [0],
                "startup: CH0B+CH0C used and re-enabled")
        t.check(f2.values["CHTE"] == [1] && c2.existing.count == 2, "startup: wrong-size CHTE ignored, never written")
        let f3 = FakeSMC(["CH0B": [2]])
        let c3 = f3.controller()
        t.check(c3.active == nil && f3.values["CH0B"] == [0], "startup: lone CH0B re-enabled; no usable key")
        let w3 = f3.writes
        step(c3, hold: true, charging(0), 3000, at: 0)
        t.check(f3.writes == w3 && !c3.inhibited, "monitor-only: never writes")
        let f0 = FakeSMC([:])
        let c0 = f0.controller()
        t.check(c0.active == nil && f0.writes == 0 && c0.batteryCurrentMA() == nil, "no keys: monitor-only, nothing written")

        // Apply: write only when different, read back, rewrite external changes, failed writes.
        let f4 = FakeSMC(["CHTE": enabled])
        let c4 = f4.controller()
        var w = f4.writes
        step(c4, hold: true, stopped(0), 0, at: 0)
        t.check(f4.values["CHTE"] == inhibited && c4.inhibited && f4.writes == w + 1, "apply: inhibit written once")
        step(c4, hold: true, stopped(0), 0, at: 5)
        t.check(f4.writes == w + 1, "apply: unchanged value not rewritten")
        f4.values["CHTE"] = enabled
        step(c4, hold: true, stopped(0), 0, at: 10)
        t.check(f4.values["CHTE"] == inhibited && f4.reports.contains { $0.contains("changed externally") },
                "apply: external change rewritten with a warning")
        step(c4, stopped(0), 0, at: 15)
        t.check(f4.values["CHTE"] == enabled && !c4.inhibited, "apply: enable written")
        f4.failWrites = true
        w = f4.writes
        step(c4, hold: true, stopped(0), 0, at: 20)
        t.check(f4.values["CHTE"] == enabled && !c4.inhibited && f4.writes == w + 2, "apply: failed inhibit answered with enable")
        t.check(!c4.enableAll("test"), "enableAll: reports writes that did not verify")
        f4.failWrites = false
        step(c4, hold: true, stopped(0), 0, at: 25)
        f4.failWrites = true
        step(c4, stopped(0), 0, at: 30)
        t.check(f4.values["CHTE"] == inhibited && c4.confirmed == nil, "apply: a failed enable leaves the state unknown")
        f4.failWrites = false
        step(c4, stopped(0), 0, at: 35)
        t.check(f4.values["CHTE"] == enabled && c4.confirmed == false, "apply: enable retried on the next tick")

        // Passive verification needs ioreg AND pmset, refreshed after the inhibit.
        let f5 = FakeSMC(["CHTE": enabled])
        let c5 = f5.controller()
        step(c5, hold: true, charging(990), 3000, at: 1000)
        step(c5, hold: true, stopped(995), 0, at: 1010)
        t.check(!c5.keyVerified, "passive: ioreg data from before the inhibit does not count")
        step(c5, hold: true, reading(80, 30, charging: false, pmset: "charging", updated: 1020), 0, at: 1025)
        t.check(!c5.keyVerified, "passive: pmset must agree")
        step(c5, hold: true, stopped(1030), 0, at: 1035)
        t.check(c5.keyVerified && c5.active?.name == "CHTE" && c5.keyDetail?.hasPrefix("verified") == true,
                "passive: ioreg + pmset not charging verifies the key")

        // Passive failure → charging re-enabled, monitor-only; a probe re-tests the key.
        let f6 = FakeSMC(["CHTE": enabled])
        let c6 = f6.controller()
        step(c6, hold: true, charging(0), 3000, at: 0)
        step(c6, hold: true, charging(60), 3000, at: 60)
        t.check(c6.active != nil && f6.values["CHTE"] == inhibited, "passive: still waiting at 60 s")
        step(c6, hold: true, charging(110), 3000, at: 121)
        t.check(c6.active == nil && f6.values["CHTE"] == enabled && !c6.inhibited,
                "passive: still charging after 120 s → key failed, charging re-enabled")
        t.check(c6.keyDetail?.contains("FAILED") == true, "passive: failure recorded")
        let w6 = f6.writes
        step(c6, hold: true, charging(130), 3000, at: 130)
        t.check(f6.writes == w6, "after a failed key: monitor-only, no writes")
        step(c6, probe: 1, charging(140), 3000, at: 140)
        t.check(c6.active?.name == "CHTE" && c6.probeRunning && f6.values["CHTE"] == inhibited,
                "probe: re-tests a key that failed earlier")

        // Inconclusive window keeps the key; a window ends when charging is re-enabled first.
        let f7 = FakeSMC(["CHTE": enabled])
        let c7 = f7.controller()
        step(c7, hold: true, charging(0), 3000, at: 0)
        step(c7, hold: true, charging(0), 0, at: 121)
        t.check(c7.active?.name == "CHTE" && !c7.keyVerified && f7.values["CHTE"] == inhibited,
                "passive: inconclusive window keeps the key")
        step(c7, charging(0), 3000, at: 130)
        step(c7, hold: true, charging(125), 3000, at: 140)
        step(c7, stopped(145), 0, at: 150)
        step(c7, stopped(155), 0, at: 160)
        t.check(!c7.keyVerified && f7.values["CHTE"] == enabled, "passive: window dropped when charging is re-enabled first")

        // Probe: skipped, verified, then normal policy.
        let f8 = FakeSMC(["CHTE": enabled])
        let c8 = f8.controller()
        step(c8, probe: 1, reading(50, 30, charging: false, ac: false, pmset: "discharging"), -800, at: 0)
        t.check(c8.probe?.request == 1 && c8.probe?.state == "skipped" && f8.values["CHTE"] == enabled,
                "probe: skipped without a charger")
        step(c8, hold: true, probe: 2, stopped(5), 0, at: 5)
        t.check(c8.probe?.state == "skipped" && c8.probe?.detail.contains("holding") == true,
                "probe: skipped while battery-tool holds charging")
        step(c8, paused: true, probe: 3, charging(10), 3000, at: 10)
        t.check(c8.probe?.state == "skipped" && c8.probe?.request == 3, "probe: skipped while paused")
        step(c8, probe: 4, charging(15), 3000, at: 20)
        t.check(c8.probeRunning && c8.probe?.state == "running" && f8.values["CHTE"] == inhibited, "probe: pauses charging")
        step(c8, probe: 4, charging(25), 3000, at: 30)
        t.check(c8.probeRunning && f8.values["CHTE"] == inhibited, "probe: normal policy suspended while waiting")
        step(c8, probe: 4, stopped(45), 0, at: 50)
        t.check(c8.keyVerified && f8.values["CHTE"] == enabled && c8.probe?.state == "running",
                "probe: confirmed → key verified, charging re-enabled")
        step(c8, hold: true, probe: 4, stopped(45), 2500, at: 55)
        t.check(c8.probe?.state == "verified" && !c8.probeRunning && c8.probe?.finishedAt == 55,
                "probe: verified once charging resumed")
        t.check(f8.values["CHTE"] == inhibited, "probe: normal policy resumes afterwards")

        // Probe aborts (paused, unreadable battery, shutdown) and failure.
        let f9 = FakeSMC(["CHTE": enabled])
        let c9 = f9.controller()
        step(c9, probe: 1, charging(0), 3000, at: 0)
        step(c9, paused: true, probe: 1, charging(0), 3000, at: 5)
        t.check(c9.probe?.state == "failed" && c9.probe?.detail.contains("aborted") == true && !c9.probeRunning
                && f9.values["CHTE"] == enabled, "probe: aborted and charging re-enabled when paused")
        step(c9, probe: 2, charging(10), 3000, at: 10)
        step(c9, probe: 2, nil, nil, at: 15)
        t.check(c9.probe?.detail.contains("aborted") == true && f9.values["CHTE"] == enabled,
                "probe: aborted when battery data is unreadable")
        step(c9, probe: 3, charging(20), 3000, at: 20)
        c9.abortProbe("the daemon is stopping", now: 25)
        t.check(c9.probe?.state == "failed" && f9.values["CHTE"] == enabled, "probe: aborted on shutdown")
        step(c9, probe: 4, charging(30), 3000, at: 30)
        step(c9, probe: 4, stopped(-3500), 0, at: -3500)                  // clock set back an hour
        t.check(c9.probe?.state == "failed" && c9.probe?.detail.contains("clock") == true && !c9.probeRunning
                && f9.values["CHTE"] == enabled, "probe: aborted and charging re-enabled when the clock is set back")
        step(c9, probe: 5, charging(30), 3000, at: 30)
        step(c9, probe: 5, charging(100), 3000, at: 151)
        t.check(c9.probe?.state == "failed" && c9.active == nil && f9.values["CHTE"] == enabled,
                "probe: still charging after 120 s → failed, charging re-enabled, monitor-only")

        let f10 = FakeSMC(["CHTE": enabled])
        let c10 = f10.controller()
        step(c10, probe: 1, charging(0), 3000, at: 0)
        f10.failWrites = true
        step(c10, probe: 1, stopped(10), 0, at: 10)
        t.check(c10.probeRunning && f10.values["CHTE"] == inhibited, "probe: the re-enable write failed once")
        f10.failWrites = false
        step(c10, probe: 1, stopped(10), 0, at: 15)
        t.check(c10.probeRunning && f10.values["CHTE"] == enabled, "probe: the re-enable is retried while waiting to resume")
        step(c10, probe: 1, stopped(10), 0, at: 131)
        t.check(c10.probe?.state == "verified" && c10.probe?.detail.contains("WARNING") == true
                && f10.values["CHTE"] == enabled, "probe: no resume within 120 s is only a warning")
        step(c10, probe: 0, charging(140), 3000, at: 140)
        t.check(!c10.probeRunning && c10.probe?.request == 1, "probe: a lower request (config reset) starts nothing")
        step(c10, probe: 1, charging(150), 3000, at: 150)
        t.check(c10.probeRunning && c10.probe?.request == 1, "probe: the next request after a reset runs")

        // state.json: a verification counts only for the same key and macOS build.
        let rec = ChargeController.KeyRecord(key: "CHTE", osBuild: "25G83", verified: true, verifiedAt: 1, detail: "ok")
        let data = try? JSONEncoder().encode(rec)
        let json = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        t.check(json.contains("\"os_build\"") && json.contains("\"verified_at\""), "state.json: snake_case keys")
        t.check(ChargeController.record(from: data, key: "CHTE", build: "25G83")?.verified == true, "state.json: same build counts")
        t.check(ChargeController.record(from: data, key: "CHTE", build: "25G90") == nil, "state.json: other build ignored")
        t.check(ChargeController.record(from: data, key: "CH0B+CH0C", build: "25G83") == nil, "state.json: other key ignored")
        t.check(ChargeController.record(from: Data("garbage".utf8), key: "CHTE", build: "25G83") == nil,
                "state.json: unparseable file ignored")
    }
}
