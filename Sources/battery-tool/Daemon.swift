import Foundation
import IOKit
import IOKit.pwr_mgt

/// `battery-tool daemon`: the root launchd job (KeepAlive). Every path fails toward
/// "charging enabled" and "everything restored".
enum Daemon {
    static func run() -> Never {
        guard geteuid() == 0 else {
            FileHandle.standardError.write(Data("battery-tool daemon must run as root (launchd starts it)\n".utf8))
            exit(1)
        }
        let core = DaemonCore()
        core.start()
        // Not dispatchMain(): that exits the main thread, and with it the alternate signal stack the
        // crash handlers need to survive a stack overflow. The main run loop drains the main queue.
        withExtendedLifetime(core) {
            RunLoop.main.add(NSMachPort(), forMode: .default)   // never runs out of sources
            while true { RunLoop.main.run() }
        }
        fatalError("unreachable")
    }

    /// Atomic replace (temp file in the same directory + rename), mode 0644.
    @discardableResult
    static func writeAtomically(_ data: Data, to path: String) -> Bool {
        let tmp = path + ".tmp"
        unlink(tmp)
        guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o644]) else {
            return false
        }
        chmod(tmp, 0o644)
        guard rename(tmp, path) == 0 else {
            unlink(tmp)
            return false
        }
        return true
    }
}

/// All daemon state. Everything runs on the main queue: poll timer, signal sources and
/// sleep/wake notifications.
private final class DaemonCore {
    // IOKit/IOMessage.h iokit_common_msg() values (the macros are not importable into Swift).
    private static let canSystemSleep: UInt32 = 0xE000_0270
    private static let systemWillSleep: UInt32 = 0xE000_0280
    private static let systemHasPoweredOn: UInt32 = 0xE000_0300

    private let log = Logger.shared
    private lazy var controller = ChargeController(log: log, report: { [unowned self] in self.remember($0) })
    private lazy var lowPower = LowPowerManager(log: log)
    private var policy = Policy()
    private var config = Config()
    /// False until a config file parsed (or none exists): until then the daemon acts as paused.
    private var configLoaded = false
    private var configSignature: [Int]?
    private var configError: String?
    private var savedPolicy: Policy.Saved?
    private var timer: DispatchSourceTimer?
    private var timerInterval = 0
    private var signalSources: [DispatchSourceSignal] = []
    private var powerPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var lockFD: Int32 = -1
    private var messages: [String] = []
    private var lastDecision: Policy.Decision?
    private var lastBattery: BatteryReading?
    private var lastBatteryError: String?
    private var lastCurrentMA: Int?
    private var lastReason = "starting"
    private var lastLogKey: String?
    private var lastStatusFailure = 0.0
    private var uninstalling = false
    private let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    func start() {
        for dir in [Paths.varDir, Paths.logDir] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o755])
        }
        log.alsoStderr = isatty(STDERR_FILENO) != 0
        lockFD = open(Paths.lockFile, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        if lockFD < 0 {
            log.error("cannot open \(Paths.lockFile) (\(String(cString: strerror(errno)))); "
                + "continuing without the single-instance lock")
        } else if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            log.error("another battery-tool daemon holds \(Paths.lockFile); exiting")
            exit(1)
        }
        log.info("battery-tool \(Paths.version) daemon starting (pid \(getpid()), macOS build \(OSInfo.build))")
        // Signals first: a SIGTERM during startup is then handled gracefully once the main queue runs.
        installSignalHandlers()

        log.info("startup: AppleSMC, charge-inhibit key detection, crash handlers, failsafe enable")
        controller.start()
        log.info("startup: restoring extreme low power mode leftovers of a previous run")
        lowPower.restoreLeftoversAtStartup()
        // The config is read only after the failsafe, so a bad file cannot delay re-enabling charging.
        reloadConfigIfChanged()
        restorePolicy()
        log.info("startup: uninstall sentinel check")
        if let path = sentinelPath(Console.currentUser()) { sentinelFlow(path) }
        log.info("startup: sleep/wake notifications")
        registerForSleep()
        guard !uninstalling else { return }
        log.info("startup: polling every \(config.pollIntervalSeconds) s")
        armTimer()
    }

    // MARK: - Tick

    private func tick() {
        guard !uninstalling else { return }
        let now = Date().timeIntervalSince1970
        reloadConfigIfChanged()
        if config.pollIntervalSeconds != timerInterval { armTimer() }
        let user = Console.currentUser()
        if let path = sentinelPath(user) {
            sentinelFlow(path)
            return
        }

        var battery: BatteryReading?
        var batteryError: String?
        do { battery = try Battery.read() } catch { batteryError = "\(error)" }
        if batteryError != lastBatteryError {
            if let e = batteryError { warn("battery data unreadable (\(e)); failsafe: charging allowed") }
            else { log.info("battery data readable again") }
        }
        let currentMA = controller.batteryCurrentMA()
        let cfg = effective
        let d = policy.decide(config: cfg, battery: battery, now: now, batteryError: batteryError)
        savePolicy()

        let wasInhibited = controller.inhibited
        controller.tick(inhibit: d.inhibit, reason: d.reason, paused: cfg.paused, probeRequest: cfg.probeRequest,
                        battery: battery, currentMA: currentMA, now: now)
        if controller.probeRunning { lastLogKey = nil } else { logTransition(d, wasInhibited: wasInhibited) }
        lowPower.reconcile(desired: d.lowPowerDesired, trigger: d.lowPowerTrigger, reason: d.lowPowerReason,
                           config: cfg, consoleUser: user)

        lastDecision = d
        lastBattery = battery
        lastBatteryError = batteryError
        lastCurrentMA = currentMA
        lastReason = chargingReason(d)
        writeStatus()
    }

    /// Logs each policy change once: charging PAUSED / RESUMED with its reason, and the duty cycle
    /// starting / stopping (never its individual phases). Only once the key is in the wanted state;
    /// failed writes are reported by the controller.
    private func logTransition(_ d: Policy.Decision, wasInhibited: Bool) {
        if controller.active != nil && controller.confirmed != d.inhibit { return }
        let key = d.kind == .duty ? "duty" : "\(d.kind) \(d.inhibit)"
        guard key != lastLogKey else { return }
        if lastLogKey == "duty" { log.info("duty cycle stopped") }
        lastLogKey = key
        if d.kind == .duty {
            log.info("duty cycle started: \(d.reason)")
        } else if controller.active == nil {
            log.info("monitor-only, charging not controlled: \(d.inhibit ? "would pause — " : "")\(d.reason)")
        } else if d.inhibit {
            log.info("charging PAUSED — \(d.reason)")
        } else if wasInhibited {
            log.info("charging RESUMED — \(d.reason)")
        } else {
            log.info("state: \(d.reason)")
        }
    }

    private func chargingReason(_ d: Policy.Decision) -> String {
        if controller.probeRunning, let p = controller.probe { return "SMC key probe running: \(p.detail)" }
        guard let key = controller.active?.name else {
            return "monitor-only (\(controller.unavailable)), charging not controlled; policy: \(d.reason)"
        }
        if controller.confirmed != d.inhibit {
            return "could not \(d.inhibit ? "pause" : "re-enable") charging via \(key) (SMC write failed; retrying "
                + "every tick) — \(d.reason)"
        }
        if !configLoaded { return "acting as paused: config.json cannot be read (\(configError ?? "?"))" }
        return d.reason
    }

    /// The config in force: the user's, or "paused" until a valid one was read.
    private var effective: Config {
        var c = config
        if !configLoaded { c.paused = true }
        return c
    }

    private var currentMode: String {
        let c = effective
        if c.paused { return "paused" }
        if !c.enabled { return "disabled" }
        return controller.active == nil ? "monitor-only" : "active"
    }

    /// Holds of a previous run (policy.json), if computed for the current thresholds.
    private func restorePolicy() {
        guard let data = FileManager.default.contents(atPath: Paths.policyFile),
              let s = try? JSONDecoder().decode(Policy.Saved.self, from: data) else { return }
        policy.restore(s, config: config)
        savedPolicy = policy.saved
        if savedPolicy != nil {
            log.info("restored hold state: charge limit \(s.limitHold == true ? "holding" : "not holding"), "
                + "heat guard \(s.heatHold == true ? "holding" : "not holding")")
        }
    }

    private func savePolicy() {
        let s = policy.saved
        guard s != savedPolicy, let s else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(s), Daemon.writeAtomically(data, to: Paths.policyFile) { savedPolicy = s }
    }

    /// Reloads when the file's mtime/size/inode changed. Unparseable → keep the last good config
    /// (warn once per distinct error); missing → defaults; values are always clamped by validated().
    private func reloadConfigIfChanged() {
        var st = stat()
        let exists = stat(Paths.configFile, &st) == 0
        let signature = exists ? [Int(st.st_mtimespec.tv_sec), Int(st.st_mtimespec.tv_nsec),
                                  Int(st.st_size), Int(truncatingIfNeeded: st.st_ino)] : []
        guard signature != configSignature else { return }
        configSignature = signature
        do {
            // A FIFO or device here would block the read forever.
            guard !exists || st.st_mode & S_IFMT == S_IFREG else {
                throw ConfigError.invalid("\(Paths.configFile) is not a regular file")
            }
            let (loaded, notes) = try Config.load().validated()
            notes.forEach { warn("config: \($0)") }
            if !configLoaded { controller.handledProbeRequest = loaded.probeRequest }   // only new requests count
            config = loaded
            configLoaded = true
            configError = nil
            log.info(exists ? "config loaded (revision \(loaded.revision))" : "no config file; using defaults")
        } catch {
            let text = "\(error)"
            if text != configError {
                warn(configLoaded ? "keeping the last good config (revision \(config.revision)): \(text)"
                                  : "no valid config yet; acting as paused (charging allowed) until it is fixed: \(text)")
            }
            configError = text
        }
    }

    private func armTimer() {
        let seconds = config.pollIntervalSeconds
        if let timer {
            timer.schedule(deadline: .now() + .seconds(seconds), repeating: .seconds(seconds), leeway: .milliseconds(250))
            log.info("poll interval now \(seconds) s")
        } else {
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.setEventHandler { [unowned self] in self.tick() }
            t.schedule(deadline: .now(), repeating: .seconds(seconds), leeway: .milliseconds(250))
            t.resume()
            timer = t
        }
        timerInterval = seconds
    }

    // MARK: - Signals and sleep

    /// Signals arrive on their own queue: charging is re-enabled at once (bt_smc_stop also blocks
    /// any later inhibit write) even if the main queue is stuck in a slow tick; the full
    /// shutdown then runs on the main queue.
    private func installSignalHandlers() {
        signal(SIGPIPE, SIG_IGN)
        let queue = DispatchQueue(label: "battery-tool.signals")
        for (sig, name) in [(SIGTERM, "SIGTERM"), (SIGINT, "SIGINT"), (SIGHUP, "SIGHUP")] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { [unowned self, log] in
                bt_smc_stop()
                log.info("\(name): charge-inhibit keys reset to \"charging enabled\"; no further inhibit writes")
                DispatchQueue.main.async { self.shutdown(name) }
            }
            source.resume()
            signalSources.append(source)
        }
        log.info("signal handlers installed (SIGTERM, SIGINT, SIGHUP → re-enable charging, graceful shutdown)")
    }

    private func registerForSleep() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        powerPort = IORegisterForSystemPower(refcon, &notifyPort, { refcon, _, type, argument in
            guard let refcon else { return }
            Unmanaged<DaemonCore>.fromOpaque(refcon).takeUnretainedValue().powerEvent(type, argument)
        }, &notifier)
        guard powerPort != 0, let port = notifyPort else {
            log.error("IORegisterForSystemPower failed; sleep/wake handling disabled")
            return
        }
        IONotificationPortSetDispatchQueue(port, .main)
    }

    private func powerEvent(_ type: UInt32, _ argument: UnsafeMutableRawPointer?) {
        switch type {
        case Self.canSystemSleep:
            IOAllowPowerChange(powerPort, Int(bitPattern: argument))
        case Self.systemWillSleep:
            prepareForSleep()
            IOAllowPowerChange(powerPort, Int(bitPattern: argument))
        case Self.systemHasPoweredOn:
            log.info("system woke up")
            policy.resetDutyCycle()
            tick()
        default:
            break
        }
    }

    /// A duty-cycle off-phase cannot end while asleep, so it must not hold charging off through
    /// sleep; limit and heat holds stay. A running probe or verification window ends here.
    private func prepareForSleep() {
        guard !uninstalling else { return }
        let now = Date().timeIntervalSince1970
        controller.abortProbe("the system is going to sleep", now: now)
        controller.cancelPassiveCheck("the system is going to sleep")
        let wasDuty = lastDecision?.kind == .duty
        policy.resetDutyCycle()
        let d = policy.decide(config: effective, battery: lastBattery, now: now, batteryError: lastBatteryError)
        controller.apply(inhibit: d.inhibit, reason: d.reason, now: now)
        lastDecision = d
        if wasDuty {
            log.info("going to sleep: duty cycle reset; charging \(controller.inhibited ? "stays paused — \(d.reason)" : "enabled")")
        }
    }

    /// SIGTERM/SIGINT/SIGHUP: re-enable charging on every candidate key (verified), restore power
    /// settings and process priorities, write status "stopped", exit 0 — within 20 s.
    private func shutdown(_ signalName: String) {
        log.info("\(signalName) received: shutting down")
        DispatchQueue.global().asyncAfter(deadline: .now() + 18) { [log] in
            log.error("shutdown still running after 18 s; exiting now (charging was re-enabled first)")
            _exit(0)
        }
        timer?.cancel()
        let now = Date().timeIntervalSince1970
        controller.abortProbe("the daemon is stopping", now: now)
        let ok = controller.enableAll("shutdown")
        lowPower.restoreAll(reason: "daemon stopping (\(signalName))")
        lastDecision = nil
        lastReason = ok ? "daemon stopped; charging enabled" : "daemon stopped; re-enabling charging could not be verified"
        writeStatus(mode: "stopped")
        log.info("stopped")
        exit(0)
    }

    // MARK: - Uninstall sentinel

    /// `<home>/Desktop/UNINSTALL-BATTERY-TOOL` for the console user and the installing user. Only
    /// stat() on the exact path: launchd jobs cannot list a TCC-protected Desktop.
    private func sentinelPath(_ user: ConsoleUser?) -> String? {
        let homes = [user?.home, InstallManifest.value("home")].compactMap { $0 }.filter { $0.hasPrefix("/") }
        for home in homes {
            let path = home + "/Desktop/" + Paths.sentinelName
            var st = stat()
            if stat(path, &st) == 0 { return path }
        }
        return nil
    }

    private func sentinelFlow(_ path: String) {
        uninstalling = true
        log.info("uninstall requested: \(path) exists")
        timer?.cancel()
        timer = nil
        controller.abortProbe("uninstall requested", now: Date().timeIntervalSince1970)
        let ok = controller.enableAll("uninstall")
        lowPower.restoreAll(reason: "uninstall requested (\(Paths.sentinelName) on the Desktop)")
        lastDecision = nil
        lastReason = ok ? "uninstalling; charging re-enabled" : "uninstalling; re-enabling charging could not be verified"
        writeStatus(mode: "uninstalling")
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [log] in
            log.warn("still running 300 s after the uninstall request; exiting so launchd restarts the daemon and retries")
            exit(0)
        }
        guard let script = [Paths.uninstallScript, Paths.menuAppUninstallScript].first(where: isTrustedScript) else {
            log.error("no usable uninstall script (\(Paths.uninstallScript), \(Paths.menuAppUninstallScript)); "
                + "staying idle with charging enabled")
            return
        }
        spawnUninstaller(script)
    }

    /// The script runs as root, so it must be a root-owned regular file that only root can modify
    /// (the menu app copy lives under admin-writable /Applications).
    private func isTrustedScript(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        guard st.st_mode & S_IFMT == S_IFREG, st.st_uid == 0, st.st_mode & 0o022 == 0 else {
            log.error("not running \(path): it must be a root-owned regular file not writable by group/others")
            return false
        }
        return true
    }

    /// `/bin/bash <script> --from-daemon` in a new session (it outlives this job's bootout), stdio on
    /// /dev/null (the script writes its own report), no inherited descriptors, default signals.
    private func spawnUninstaller(_ script: String) {
        var attr: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        posix_spawnattr_init(&attr)
        posix_spawn_file_actions_init(&actions)
        defer {
            posix_spawnattr_destroy(&attr)
            posix_spawn_file_actions_destroy(&actions)
        }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT
                                              | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var defaults = sigset_t(), none = sigset_t()
        sigemptyset(&defaults)
        sigemptyset(&none)
        for sig in [SIGTERM, SIGINT, SIGHUP, SIGPIPE] { sigaddset(&defaults, sig) }
        posix_spawnattr_setsigdefault(&attr, &defaults)
        posix_spawnattr_setsigmask(&attr, &none)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        let args: [String] = ["/bin/bash", script, "--from-daemon"]
        let env: [String] = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin"]
        let argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup($0) } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let r = posix_spawn(&pid, "/bin/bash", &actions, &attr, argv, envp)
        guard r == 0 else {
            log.error("could not start \(script): \(String(cString: strerror(r))); staying idle with charging enabled")
            return
        }
        log.info("started /bin/bash \(script) --from-daemon (pid \(pid)); waiting for it to unload this daemon")
        DispatchQueue.global().async { [log] in
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            log.info("uninstall script (pid \(pid)) exited with status \((status >> 8) & 0xff)")
        }
    }

    // MARK: - status.json

    private func writeStatus(mode: String? = nil) {
        var s = DaemonStatus()
        s.updatedAt = Date().timeIntervalSince1970
        s.daemonPid = getpid()
        s.appliedConfigRevision = config.revision
        s.mode = mode ?? currentMode
        s.battery = lastBattery
        s.batteryError = lastBatteryError
        s.batteryCurrentMA = lastCurrentMA
        s.charging.inhibited = controller.confirmed != false     // unknown (failed write) may still block
        s.charging.reason = lastReason
        s.charging.key = controller.active?.name
        s.charging.keyVerified = controller.keyVerified
        s.charging.keyDetail = controller.keyDetail
        s.charging.limitHold = lastDecision?.limitHold ?? false
        s.charging.heatHold = lastDecision?.heatHold ?? false
        s.dutyCycle.active = lastDecision?.dutyPhase != nil
        s.dutyCycle.phase = lastDecision?.dutyPhase
        s.dutyCycle.phaseEndsAt = lastDecision?.dutyPhaseEndsAt
        s.lowpower = lowPower.snapshot()
        s.probe = controller.probe
        s.messages = messages
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(s), Daemon.writeAtomically(data, to: Paths.statusFile) { return }
        let now = Date().timeIntervalSince1970
        if now - lastStatusFailure >= 300 {
            lastStatusFailure = now
            log.error("could not write \(Paths.statusFile)")
        }
    }

    private func warn(_ message: String) {
        log.warn(message)
        remember(message)
    }

    /// status.json `messages`: the last 10 warnings, newest last.
    private func remember(_ message: String) {
        messages.append("\(clock.string(from: Date())) \(message)")
        if messages.count > 10 { messages.removeFirst(messages.count - 10) }
    }
}
