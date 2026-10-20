import Foundation

/// `battery-tool selftest`: pure-logic tests that need no root and touch nothing.
final class TestRunner {
    private(set) var passed = 0
    private(set) var failed = 0

    func check(_ condition: @autoclosure () -> Bool, _ name: String, file: StaticString = #fileID, line: UInt = #line) {
        if condition() {
            passed += 1
        } else {
            failed += 1
            print("FAIL: \(name) (\(file):\(line))")
        }
    }
}

enum SelfTest {
    static func run() -> Int32 {
        let t = TestRunner()
        SharedSelfTests.run(t)
        PolicySelfTests.run(t)
        LowPowerSelfTests.run(t)
        AudioProtectSelfTests.run(t)
        print("selftest: \(t.passed) passed, \(t.failed) failed")
        return t.failed == 0 ? 0 : 1
    }
}

enum SharedSelfTests {
    static func run(_ t: TestRunner) {
        // Config: defaults, partial JSON, clamping.
        let d = Config()
        t.check(d.chargeLimit.maxPercent == 80 && d.chargeLimit.resumePercent == 75, "config default limit 80/75")
        t.check(d.heatGuard.limitC == 35 && d.heatGuard.resumeC == 32, "config default heat 35/32")
        t.check(!d.lowpower.enabled && !d.lowpower.autoTrigger.enabled && d.lowpower.autoTrigger.tempC == 40,
                "extreme LPM off by default, auto-trigger 40")
        t.check(d.lowpower.protected == ["Finder", "Dock", "Terminal", "@frontmost"], "default protected list")
        let partial = try? JSONDecoder().decode(Config.self, from: Data(#"{"charge_limit":{"max_percent":90}}"#.utf8))
        t.check(partial?.chargeLimit.maxPercent == 90 && partial?.chargeLimit.resumePercent == 75
                && partial?.heatGuard.limitC == 35, "partial config falls back to defaults")
        var bad = Config()
        bad.chargeLimit.maxPercent = 150
        bad.chargeLimit.resumePercent = 200
        bad.heatGuard.limitC = .nan
        bad.dutyCycle.warmC = 99
        let (v, notes) = bad.validated()
        t.check(v.chargeLimit.maxPercent == 100 && v.chargeLimit.resumePercent == 99, "clamp limit")
        t.check(v.heatGuard.limitC == 25 && v.dutyCycle.warmC == 60, "clamp NaN heat limit and warm")
        var lowHeat = Config()
        lowHeat.heatGuard.limitC = 25
        t.check(lowHeat.validated().0.dutyCycle.warmC == 32, "a lowered heat limit leaves the warm threshold alone")
        t.check(notes.count >= 3, "validation reports changes")
        // Settings window: edits are copied onto the current file; runtime state stays.
        var onDisk = Config()
        onDisk.paused = true
        onDisk.lowpower.enabled = true
        onDisk.probeRequest = 7
        onDisk.revision = 41
        var edited = Config()
        edited.paused = false
        edited.lowpower.enabled = false
        edited.chargeLimit = Config.ChargeLimit(maxPercent: 85, resumePercent: 70)
        edited.heatGuard.limitC = 37
        edited.dutyCycle.enabled = true
        edited.lowpower.autoTrigger.enabled = true
        edited.lowpower.protected = ["Music", "@frontmost"]
        edited.pollIntervalSeconds = 3
        let merged = edited.applyingEdits(onto: onDisk)
        t.check(merged.paused && merged.lowpower.enabled && merged.probeRequest == 7 && merged.revision == 42,
                "settings: paused, manual extreme LPM and probe counter kept; revision bumped")
        t.check(merged.chargeLimit.maxPercent == 85 && merged.heatGuard.limitC == 37 && merged.dutyCycle.enabled
                && merged.lowpower.autoTrigger.enabled && merged.lowpower.protected == ["Music", "@frontmost"]
                && merged.pollIntervalSeconds == 3, "settings: edited values copied")
        // Three-way: the CLI changed the limit while the window was open; the window only edited the heat guard.
        var cli = onDisk
        cli.chargeLimit = Config.ChargeLimit(maxPercent: 90, resumePercent: 85)
        var window = Config()
        window.heatGuard.limitC = 38
        let three = window.applyingEdits(onto: cli, since: Config())
        t.check(three.chargeLimit.maxPercent == 90 && three.heatGuard.limitC == 38 && three.revision == 42,
                "settings: untouched fields keep the CLI's newer values")

        if let enc = try? Config().encoded(), let back = try? JSONDecoder().decode(Config.self, from: enc) {
            t.check(back == Config(), "config round-trips")
        } else {
            t.check(false, "config encodes")
        }

        // pmset -g batt parsing (real outputs captured on this Mac).
        let ac = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=38600803)\t49%; AC attached; not charging present: true\n"
        let p1 = Battery.parsePmsetBatt(ac)
        t.check(p1.percent == 49 && p1.state == "AC attached; not charging" && p1.source == "AC Power", "pmset AC not charging")
        let dis = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=38600803)\t47%; discharging; 1:54 remaining present: true\n"
        let p2 = Battery.parsePmsetBatt(dis)
        t.check(p2.percent == 47 && p2.state == "discharging" && p2.source == "Battery Power", "pmset discharging")
        let chg = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=38600803)\t50%; charging; (no estimate) present: true\n"
        t.check(Battery.parsePmsetBatt(chg).state == "charging", "pmset charging, no estimate")

        // pmset -g custom parsing.
        let custom = "Battery Power:\n Sleep On Power Button 1\n lowpowermode         0\n standby 1\nAC Power:\n lowpowermode         1\n"
        let lpm = PowerSettings.parseLowPowerModes(custom)
        t.check(lpm.battery == 0 && lpm.ac == 1, "pmset custom lowpowermode")

        // ioreg dictionary → reading; implausible temperature must throw.
        let io: [String: Any] = ["Temperature": 3042, "CurrentCapacity": 47, "MaxCapacity": 100,
                                 "IsCharging": false, "ExternalConnected": false, "FullyCharged": false]
        let r = try? Battery.reading(fromIoreg: io, pmsetOutput: dis)
        t.check(r?.temperatureC == 30.42 && r?.percent == 47 && r?.isCharging == false, "ioreg reading")
        var hot = io
        hot["Temperature"] = 25000
        t.check((try? Battery.reading(fromIoreg: hot, pmsetOutput: nil)) == nil, "implausible temperature rejected")
        var noTemp = io
        noTemp["Temperature"] = nil
        t.check((try? Battery.reading(fromIoreg: noTemp, pmsetOutput: nil)) == nil, "missing temperature rejected")

        // After bt_smc_stop() a non-zero (inhibit) write is refused before it reaches the SMC.
        // Nothing is registered for emergency replay in this process, so nothing is written.
        if bt_smc_open() == 0 {
            var info: UInt32 = 0
            if bt_smc_key_info("CHTE", &info, nil) == 0 {
                bt_smc_stop()
                t.check(bt_smc_write("CHTE", [1, 0, 0, 0], 4) == BT_SMC_REFUSED, "inhibit write refused after stop")
            }
            bt_smc_close()
        }
    }
}
