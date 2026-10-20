import Foundation

/// The per-tick decision: inhibit charging or not (and why), and whether extreme low
/// power mode is wanted. Pure logic; all hysteresis and duty-cycle state lives in this
/// struct, so PolicySelfTests can drive it with synthetic readings.
struct Policy {
    struct Decision {
        enum Kind { case paused, disabled, failsafe, heat, limit, duty, allowed }
        var kind: Kind
        var inhibit = false
        var reason: String
        var limitHold = false
        var heatHold = false
        var dutyPhase: String?            // "on" | "off" while the duty cycle runs
        var dutyPhaseEndsAt: Double?
        var lowPowerDesired = false
        var lowPowerTrigger: String?      // "manual" | "auto"; nil when not desired
        var lowPowerReason = ""           // why extreme LPM is wanted or not, for the log
    }

    /// The holds and the thresholds they were computed for; persisted so a daemon restart inside a
    /// hold keeps waiting for the resume point (Paths.policyFile).
    struct Saved: Codable, Equatable {
        var limitHold: Bool?
        var heatHold: Bool?
        var maxPercent: Int
        var resumePercent: Int
        var limitC: Double

        enum CodingKeys: String, CodingKey {
            case limitHold = "limit_hold", heatHold = "heat_hold", maxPercent = "max_percent"
            case resumePercent = "resume_percent", limitC = "limit_c"
        }
    }

    /// nil = no reading under the current thresholds yet: the next one applies the initial rule.
    private(set) var limitHold: Bool?
    private(set) var heatHold: Bool?
    private(set) var autoActive = false
    private(set) var dutyPhase: String?
    private(set) var dutyPhaseEndsAt: Double?
    private var limitBasis: Config.ChargeLimit?
    private var heatBasis: Double?
    private var autoBasis: Double?

    mutating func decide(config: Config, battery: BatteryReading?, now: Double,
                         batteryError: String? = nil) -> Decision {
        updateAutoTrigger(config.lowpower.autoTrigger, temperature: battery?.temperatureC)
        let lpm = !config.paused && (config.lowpower.enabled || autoActive)
        let lpmReason = lowPowerReason(config, battery, desired: lpm)
        func decision(_ kind: Decision.Kind, _ reason: String) -> Decision {
            Decision(kind: kind, reason: reason, lowPowerDesired: lpm,
                     lowPowerTrigger: lpm ? (config.lowpower.enabled ? "manual" : "auto") : nil,
                     lowPowerReason: lpmReason)
        }
        if config.paused {
            resetHolds()
            return decision(.paused, "paused")
        }
        if !config.enabled {
            resetHolds()
            return decision(.disabled, "charge control disabled")
        }
        guard let b = battery else {
            resetDutyCycle()
            return decision(.failsafe, "failsafe: battery data unreadable" + (batteryError.map { " (\($0))" } ?? ""))
        }
        let p = b.percent, t = b.temperatureC
        let limit = config.chargeLimit, heat = config.heatGuard, duty = config.dutyCycle

        // Raising a limit re-applies the initial rule (raising it at 87% lets it charge); a stricter or
        // resume-only change keeps a running hold until the new resume point.
        if limitBasis != limit {
            if let old = limitBasis, limit.maxPercent > old.maxPercent { limitHold = nil }
            limitBasis = limit
        }
        if limit.maxPercent >= 100 { limitHold = false }                   // 100% = no charge limit
        else if p >= limit.maxPercent { limitHold = true }
        else if p <= limit.resumePercent || limitHold == nil { limitHold = false }

        if heatBasis != heat.limitC {
            if let old = heatBasis, heat.limitC > old { heatHold = nil }
            heatBasis = heat.limitC
        }
        if t >= heat.limitC { heatHold = true }
        else if t <= heat.resumeC || heatHold == nil { heatHold = false }

        let lh = limitHold == true, hh = heatHold == true
        if duty.enabled && !lh && !hh && t >= duty.warmC { advanceDutyCycle(duty, now: now) } else { resetDutyCycle() }

        var d: Decision
        if hh {
            d = decision(.heat, t >= heat.limitC
                ? "heat guard: \(f(t)) °C ≥ \(f(heat.limitC)) °C (resumes ≤ \(f(heat.resumeC)) °C)"
                : "heat guard: \(f(t)) °C, cooling down (limit \(f(heat.limitC)) °C; resumes ≤ \(f(heat.resumeC)) °C)")
        } else if lh {
            d = decision(.limit, p >= limit.maxPercent
                ? "charge limit: \(p)% ≥ \(limit.maxPercent)% (resumes ≤ \(limit.resumePercent)%)"
                : "charge limit: \(p)% (limit \(limit.maxPercent)% reached; resumes ≤ \(limit.resumePercent)%)")
        } else if let phase = dutyPhase {
            d = decision(.duty, "duty cycle \(phase)-phase (\(f(t)) °C ≥ warm \(f(duty.warmC)) °C; "
                + "\(duty.onSeconds) s on / \(duty.offSeconds) s off)")
        } else {
            let pct = limit.maxPercent >= 100 ? "\(p)%, no charge limit" : "\(p)% < \(limit.maxPercent)%"
            d = decision(.allowed, "charging allowed (\(pct); \(f(t)) °C < \(f(heat.limitC)) °C)")
        }
        d.inhibit = lh || hh || dutyPhase == "off"
        d.limitHold = lh
        d.heatHold = hh
        d.dutyPhase = dutyPhase
        d.dutyPhaseEndsAt = dutyPhaseEndsAt
        return d
    }

    var saved: Saved? {
        guard let l = limitBasis, let h = heatBasis else { return nil }
        return Saved(limitHold: limitHold, heatHold: heatHold, maxPercent: l.maxPercent,
                     resumePercent: l.resumePercent, limitC: h)
    }

    /// Restores holds saved by a previous run, but only if they were computed for today's thresholds.
    mutating func restore(_ s: Saved, config: Config) {
        let l = config.chargeLimit
        guard s.maxPercent == l.maxPercent, s.resumePercent == l.resumePercent, s.limitC == config.heatGuard.limitC else { return }
        limitHold = s.limitHold
        heatHold = s.heatHold
        limitBasis = l
        heatBasis = s.limitC
    }

    /// Forgets the duty-cycle phase; the next warm tick starts a fresh "on" phase (used around sleep).
    mutating func resetDutyCycle() {
        dutyPhase = nil
        dutyPhaseEndsAt = nil
    }

    private mutating func resetHolds() {
        limitHold = nil
        heatHold = nil
        resetDutyCycle()
    }

    /// "on" for onSeconds, then "off" for offSeconds, repeating. A running phase never lasts longer
    /// than its configured length from now (a shortened setting or the clock being set back).
    private mutating func advanceDutyCycle(_ duty: Config.DutyCycle, now: Double) {
        func length(_ phase: String) -> Double { Double(phase == "on" ? duty.onSeconds : duty.offSeconds) }
        guard let phase = dutyPhase, let end = dutyPhaseEndsAt else {
            dutyPhase = "on"
            dutyPhaseEndsAt = now + length("on")
            return
        }
        let capped = min(end, now + length(phase))
        if now >= capped {
            let next = phase == "on" ? "off" : "on"
            dutyPhase = next
            dutyPhaseEndsAt = now + length(next)
        } else {
            dutyPhaseEndsAt = capped
        }
    }

    /// Set at ≥ tempC, released at ≤ tempC − 3 °C, when the trigger is off, or without battery data.
    private mutating func updateAutoTrigger(_ auto: Config.LowPower.AutoTrigger, temperature: Double?) {
        guard auto.enabled, let t = temperature else {
            autoActive = false
            autoBasis = nil
            return
        }
        if autoBasis != auto.tempC {                      // raising the threshold re-evaluates from scratch
            if let old = autoBasis, auto.tempC > old { autoActive = false }
            autoBasis = auto.tempC
        }
        if t >= auto.tempC { autoActive = true } else if t <= auto.releaseC { autoActive = false }
    }

    private func lowPowerReason(_ c: Config, _ b: BatteryReading?, desired: Bool) -> String {
        let auto = c.lowpower.autoTrigger
        if c.paused { return "battery-tool paused" }
        if c.lowpower.enabled { return "manual (battery-tool lowpower on)" }
        guard auto.enabled else { return "turned off" }
        guard let t = b?.temperatureC else { return "auto-trigger released: battery data unreadable" }
        return desired ? "auto-trigger: \(f(t)) °C (on at ≥ \(f(auto.tempC)) °C, off at ≤ \(f(auto.releaseC)) °C)"
                       : "auto-trigger released: \(f(t)) °C (on at ≥ \(f(auto.tempC)) °C, off at ≤ \(f(auto.releaseC)) °C)"
    }

    private func f(_ v: Double) -> String { String(format: "%.1f", v) }
}

/// Component A's part of `battery-tool selftest`: the policy here, ChargeController against a
/// fake SMC in ChargeController.swift. Pure: no root, touches nothing.
enum PolicySelfTests {
    static func run(_ t: TestRunner) {
        limitTests(t)
        heatTests(t)
        dutyCycleTests(t)
        modeTests(t)
        lowPowerTests(t)
        controllerTests(t)
    }

    static func reading(_ percent: Int, _ temp: Double, charging: Bool = true, ac: Bool = true,
                        pmset: String = "charging", updated: Int? = nil) -> BatteryReading {
        BatteryReading(percent: percent, temperatureC: temp, isCharging: charging, externalConnected: ac,
                       fullyCharged: false, pmsetState: pmset, ioregUpdateTime: updated)
    }

    private static func limitTests(_ t: TestRunner) {
        let c = Config()                                                     // 80 / 75, heat 35 °C
        var a = Policy()
        let mid = a.decide(config: c, battery: reading(78, 30), now: 0)
        t.check(!mid.inhibit && !mid.limitHold && mid.kind == .allowed, "limit: initial 78% (between 75 and 80) charges")
        t.check(mid.reason == "charging allowed (78% < 80%; 30.0 °C < 35.0 °C)", "limit: allowed reason text")
        var b = Policy()
        let high = b.decide(config: c, battery: reading(85, 30), now: 0)
        t.check(high.inhibit && high.limitHold && high.kind == .limit, "limit: initial 85% holds")
        t.check(high.reason == "charge limit: 85% ≥ 80% (resumes ≤ 75%)", "limit: reason text")

        let steps: [(Int, Bool)] = [(70, false), (79, false), (80, true), (79, true), (76, true),
                                    (75, false), (76, false), (79, false), (80, true), (100, true)]
        var s = Policy()
        for (i, (pct, want)) in steps.enumerated() {
            t.check(s.decide(config: c, battery: reading(pct, 30), now: Double(i)).inhibit == want,
                    "limit hysteresis step \(i): \(pct)% → \(want ? "hold" : "charge")")
        }

        var h = Policy()
        _ = h.decide(config: c, battery: reading(80, 30), now: 0)
        let held = h.decide(config: c, battery: reading(78, 30), now: 1)
        t.check(held.inhibit && held.reason == "charge limit: 78% (limit 80% reached; resumes ≤ 75%)",
                "limit: hold text below the max")

        var r = Policy()
        _ = r.decide(config: c, battery: reading(87, 30), now: 0)
        var raised = c
        raised.chargeLimit = Config.ChargeLimit(maxPercent: 90, resumePercent: 85)
        t.check(!r.decide(config: raised, battery: reading(87, 30), now: 1).inhibit,
                "limit: raising the limit re-applies the initial rule (87% < 90% charges)")
        var lowered = c
        lowered.chargeLimit = Config.ChargeLimit(maxPercent: 60, resumePercent: 55)
        t.check(r.decide(config: lowered, battery: reading(70, 30), now: 2).inhibit, "limit: lowering the limit holds at once")

        for (mx, rs) in [(79, 74), (80, 70)] {
            var tight = Policy()
            _ = tight.decide(config: c, battery: reading(80, 30), now: 0)
            var stricter = c
            stricter.chargeLimit = Config.ChargeLimit(maxPercent: mx, resumePercent: rs)
            t.check(tight.decide(config: stricter, battery: reading(78, 30), now: 1).inhibit,
                    "limit: a stricter \(mx)/\(rs) keeps the running hold at 78%")
            t.check(!tight.decide(config: stricter, battery: reading(rs, 30), now: 2).inhibit, "limit: released at the new resume \(rs)%")
        }

        var saved = Policy()
        _ = saved.decide(config: c, battery: reading(80, 36), now: 0)
        let snapshot = saved.saved
        var restarted = Policy()
        if let snap = snapshot { restarted.restore(snap, config: c) }
        let afterRestart = restarted.decide(config: c, battery: reading(78, 34), now: 1)
        t.check(afterRestart.limitHold && afterRestart.heatHold, "restart: saved holds survive (78%, 34 °C still held)")
        var otherThresholds = Policy()
        var changed = c
        changed.heatGuard.limitC = 36
        if let snap = snapshot { otherThresholds.restore(snap, config: changed) }
        t.check(!otherThresholds.decide(config: changed, battery: reading(78, 34), now: 1).inhibit,
                "restart: saved holds ignored when the thresholds changed")

        var full = c
        full.chargeLimit = Config.ChargeLimit(maxPercent: 100, resumePercent: 95)
        var m = Policy()
        let d100 = m.decide(config: full, battery: reading(100, 30), now: 0)
        t.check(!d100.inhibit && !d100.limitHold && d100.reason == "charging allowed (100%, no charge limit; 30.0 °C < 35.0 °C)",
                "limit: max 100 means no charge limit")
        t.check(!m.decide(config: full, battery: reading(97, 30), now: 1).inhibit, "limit: max 100 never holds")
        t.check(m.decide(config: full, battery: reading(100, 36), now: 2).inhibit, "limit: max 100 keeps the heat guard")
    }

    private static func heatTests(_ t: TestRunner) {
        let c = Config()                                                     // 35 °C, resumes ≤ 32 °C
        var a = Policy()
        t.check(!a.decide(config: c, battery: reading(50, 33), now: 0).inhibit, "heat: initial 33 °C (between 32 and 35) charges")
        var b = Policy()
        let hot = b.decide(config: c, battery: reading(50, 35.4), now: 0)
        t.check(hot.inhibit && hot.heatHold && hot.kind == .heat, "heat: initial 35.4 °C holds")
        t.check(hot.reason == "heat guard: 35.4 °C ≥ 35.0 °C (resumes ≤ 32.0 °C)", "heat: reason text")
        let cooling = b.decide(config: c, battery: reading(50, 33.5), now: 1)
        t.check(cooling.inhibit && cooling.reason == "heat guard: 33.5 °C, cooling down (limit 35.0 °C; resumes ≤ 32.0 °C)",
                "heat: cooling-down text")

        let steps: [(Double, Bool)] = [(34.9, false), (35.0, true), (33.0, true), (32.1, true),
                                       (32.0, false), (34.0, false), (35.0, true)]
        var s = Policy()
        for (i, (temp, want)) in steps.enumerated() {
            t.check(s.decide(config: c, battery: reading(50, temp), now: Double(i)).inhibit == want,
                    "heat hysteresis step \(i): \(temp) °C → \(want ? "hold" : "charge")")
        }

        var both = Policy()
        let d = both.decide(config: c, battery: reading(85, 36), now: 0)
        t.check(d.inhibit && d.kind == .heat && d.limitHold && d.heatHold && d.reason.hasPrefix("heat guard: 36.0 °C"),
                "priority: heat guard over charge limit")
        let limitOnly = both.decide(config: c, battery: reading(85, 31), now: 1)
        t.check(limitOnly.inhibit && limitOnly.kind == .limit && !limitOnly.heatHold, "priority: charge limit once cooled")

        var r = Policy()
        _ = r.decide(config: c, battery: reading(50, 38), now: 0)
        var raised = c
        raised.heatGuard.limitC = 40
        t.check(!r.decide(config: raised, battery: reading(50, 38), now: 1).inhibit,
                "heat: raising the limit re-applies the initial rule (38 °C < 40 °C charges)")

        var tight = Policy()
        _ = tight.decide(config: c, battery: reading(50, 35.4), now: 0)
        _ = tight.decide(config: c, battery: reading(50, 33.5), now: 1)
        var lower = c
        lower.heatGuard.limitC = 34
        t.check(tight.decide(config: lower, battery: reading(50, 33.5), now: 2).inhibit,
                "heat: lowering the limit keeps the running hold (33.5 °C, resumes ≤ 31 °C)")
        t.check(tight.decide(config: lower, battery: reading(50, 31.1), now: 3).inhibit
                && !tight.decide(config: lower, battery: reading(50, 31), now: 4).inhibit, "heat: released at the new resume point")
    }

    private static func dutyCycleTests(_ t: TestRunner) {
        var c = Config()
        c.dutyCycle = Config.DutyCycle(enabled: true, warmC: 32, onSeconds: 30, offSeconds: 60)
        let warm = reading(50, 33.1)
        var p = Policy()
        let d0 = p.decide(config: c, battery: warm, now: 1000)
        t.check(!d0.inhibit && d0.kind == .duty && d0.dutyPhase == "on" && d0.dutyPhaseEndsAt == 1030,
                "duty: starts with the on-phase")
        t.check(d0.reason == "duty cycle on-phase (33.1 °C ≥ warm 32.0 °C; 30 s on / 60 s off)", "duty: on-phase text")
        t.check(!p.decide(config: c, battery: warm, now: 1029).inhibit, "duty: still on after 29 s")
        let off = p.decide(config: c, battery: warm, now: 1030)
        t.check(off.inhibit && off.dutyPhase == "off" && off.dutyPhaseEndsAt == 1090, "duty: off after on_seconds")
        t.check(off.reason == "duty cycle off-phase (33.1 °C ≥ warm 32.0 °C; 30 s on / 60 s off)", "duty: off-phase text")
        t.check(p.decide(config: c, battery: warm, now: 1089).inhibit, "duty: still off after 59 s")
        let on2 = p.decide(config: c, battery: warm, now: 1090)
        t.check(!on2.inhibit && on2.dutyPhase == "on" && on2.dutyPhaseEndsAt == 1120, "duty: on again after off_seconds")
        t.check(p.decide(config: c, battery: warm, now: 1121).inhibit, "duty: second off-phase")

        let cool = p.decide(config: c, battery: reading(50, 31.9), now: 1125)
        t.check(!cool.inhibit && cool.dutyPhase == nil && cool.kind == .allowed, "duty: leaving the warm condition stops it")
        let again = p.decide(config: c, battery: warm, now: 1126)
        t.check(!again.inhibit && again.dutyPhase == "on" && again.dutyPhaseEndsAt == 1156, "duty: re-entering restarts with on")

        _ = p.decide(config: c, battery: warm, now: 1156)                    // off until 1216
        var short = c
        short.dutyCycle.offSeconds = 10
        let capped = p.decide(config: short, battery: warm, now: 1160)
        t.check(capped.inhibit && capped.dutyPhaseEndsAt == 1170, "duty: a shorter off_seconds caps the running phase")
        let back = p.decide(config: short, battery: warm, now: 500)             // clock set back
        t.check(back.inhibit && back.dutyPhaseEndsAt == 510, "duty: clock set back cannot stretch a phase")

        var lim = Policy()
        let dl = lim.decide(config: c, battery: reading(85, 33.1), now: 0)
        t.check(dl.kind == .limit && dl.dutyPhase == nil, "duty: not running during a charge-limit hold")
        var hot = Policy()
        let dh = hot.decide(config: c, battery: reading(50, 35), now: 0)
        t.check(dh.kind == .heat && dh.dutyPhase == nil, "duty: not running during the heat guard")
        var disabled = c
        disabled.dutyCycle.enabled = false
        var dp = Policy()
        t.check(dp.decide(config: disabled, battery: warm, now: 0).dutyPhase == nil, "duty: off when disabled")
        var nb = Policy()
        _ = nb.decide(config: c, battery: warm, now: 0)
        _ = nb.decide(config: c, battery: warm, now: 30)
        t.check(nb.decide(config: c, battery: nil, now: 31).dutyPhase == nil
                && nb.decide(config: c, battery: warm, now: 32).dutyPhase == "on", "duty: missing battery data resets it")

        var s = Policy()
        _ = s.decide(config: c, battery: warm, now: 0)
        t.check(s.decide(config: c, battery: warm, now: 30).inhibit, "duty: off-phase before sleep")
        s.resetDutyCycle()
        let afterReset = s.decide(config: c, battery: warm, now: 31)
        t.check(!afterReset.inhibit && afterReset.dutyPhase == "on", "duty: reset (sleep) restarts with the on-phase")
    }

    private static func modeTests(_ t: TestRunner) {
        var c = Config()
        c.lowpower.enabled = true
        var paused = c
        paused.paused = true
        var disabled = c
        disabled.enabled = false

        var p = Policy()
        t.check(p.decide(config: c, battery: reading(85, 36), now: 0).inhibit, "mode: active config holds")
        let dp = p.decide(config: paused, battery: reading(85, 36), now: 1)
        t.check(!dp.inhibit && dp.kind == .paused && dp.reason == "paused" && !dp.limitHold && !dp.heatHold,
                "paused: no inhibit")
        t.check(!dp.lowPowerDesired && dp.lowPowerTrigger == nil, "paused: extreme LPM not desired")
        let dd = p.decide(config: disabled, battery: reading(85, 36), now: 2)
        t.check(!dd.inhibit && dd.kind == .disabled && dd.reason == "charge control disabled", "disabled: no inhibit")
        t.check(dd.lowPowerDesired && dd.lowPowerTrigger == "manual", "disabled: manual extreme LPM unaffected")
        let df = p.decide(config: c, battery: nil, now: 3, batteryError: "ioreg failed: timeout")
        t.check(!df.inhibit && df.kind == .failsafe && df.reason == "failsafe: battery data unreadable (ioreg failed: timeout)",
                "battery nil: failsafe allows charging")
        t.check(df.lowPowerDesired && df.lowPowerTrigger == "manual", "battery nil: manual extreme LPM stays")
        t.check(p.decide(config: paused, battery: nil, now: 4).reason == "paused", "priority: paused over failsafe")
        t.check(p.decide(config: disabled, battery: nil, now: 5).reason == "charge control disabled",
                "priority: disabled over failsafe")

        var q = Policy()
        _ = q.decide(config: c, battery: reading(80, 30), now: 0)
        _ = q.decide(config: paused, battery: reading(78, 30), now: 1)
        t.check(!q.decide(config: c, battery: reading(78, 30), now: 2).inhibit, "resume after pause applies the initial rule")
        var r = Policy()
        _ = r.decide(config: c, battery: reading(80, 36), now: 0)
        _ = r.decide(config: c, battery: nil, now: 1)
        t.check(r.decide(config: c, battery: reading(78, 34), now: 2).inhibit, "battery nil keeps the hold state for later")
    }

    private static func lowPowerTests(_ t: TestRunner) {
        var c = Config()
        c.lowpower.autoTrigger = Config.LowPower.AutoTrigger(enabled: true, tempC: 40)
        var p = Policy()
        let steps: [(Double, Bool)] = [(39.9, false), (40.0, true), (38.0, true), (37.1, true),
                                       (37.0, false), (39.0, false), (40.5, true)]
        for (i, (temp, want)) in steps.enumerated() {
            let d = p.decide(config: c, battery: reading(50, temp), now: Double(i))
            t.check(d.lowPowerDesired == want && d.lowPowerTrigger == (want ? "auto" : nil),
                    "auto trigger step \(i): \(temp) °C → \(want ? "on" : "off")")
        }
        t.check(!p.decide(config: c, battery: nil, now: 10).lowPowerDesired, "auto trigger: released without battery data")
        var manual = c
        manual.lowpower.enabled = true
        t.check(p.decide(config: manual, battery: reading(50, 41), now: 11).lowPowerTrigger == "manual",
                "auto trigger: manual + auto reports manual")
        var paused = manual
        paused.paused = true
        t.check(!p.decide(config: paused, battery: reading(50, 41), now: 12).lowPowerDesired, "auto trigger: not while paused")
        var disabled = c
        disabled.enabled = false
        t.check(p.decide(config: disabled, battery: reading(50, 41), now: 13).lowPowerTrigger == "auto",
                "auto trigger: independent of charge control")
        var off = c
        off.lowpower.autoTrigger.enabled = false
        var q = Policy()
        t.check(!q.decide(config: off, battery: reading(50, 45), now: 0).lowPowerDesired, "auto trigger off: never desired")
        var r = Policy()
        t.check(!r.decide(config: c, battery: reading(50, 38), now: 0).lowPowerDesired,
                "auto trigger: initial 38 °C (between 37 and 40) stays off")

        var why = Policy()
        t.check(why.decide(config: c, battery: reading(50, 40.2), now: 0).lowPowerReason
                == "auto-trigger: 40.2 °C (on at ≥ 40.0 °C, off at ≤ 37.0 °C)", "auto trigger: reason when on")
        t.check(why.decide(config: c, battery: reading(50, 36.9), now: 1).lowPowerReason
                == "auto-trigger released: 36.9 °C (on at ≥ 40.0 °C, off at ≤ 37.0 °C)", "auto trigger: reason when released")
        var lowered = c
        lowered.lowpower.autoTrigger.tempC = 39
        var keep = Policy()
        _ = keep.decide(config: c, battery: reading(50, 40), now: 0)
        t.check(keep.decide(config: lowered, battery: reading(50, 38), now: 1).lowPowerDesired,
                "auto trigger: lowering the threshold keeps it on until ≤ 36 °C")
    }
}
