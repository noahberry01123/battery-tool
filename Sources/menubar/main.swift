import AppKit

// Battery Tool menu bar app. Runs as the logged-in user (LaunchAgent
// local.battery-tool.menubar). It displays what the root daemon reports in
// status.json, changes settings through the `battery-tool` CLI or (Settings
// window) the admin-writable config.json, and never touches the SMC or power
// settings itself. Uninstall runs uninstall.sh as root behind the macOS
// administrator password prompt.

/// Everything the menu shows, gathered off the main thread.
struct Snapshot {
    /// nil when status.json is missing or stale (daemon not running).
    var status: DaemonStatus?
    /// nil when the config cannot be read.
    var config: Config?
    var battery: BatteryReading?
    var batteryError: String?
    var lowPower: (battery: Int?, ac: Int?) = (nil, nil)

    /// Daemon status if fresh, else live battery + Low Power Mode readings. Blocks; call off-main.
    static func read() -> Snapshot {
        var s = Snapshot()
        var st = stat()   // only a regular file: a FIFO would hang this refresh for good
        if stat(Paths.configFile, &st) != 0 || st.st_mode & S_IFMT == S_IFREG {
            s.config = (try? Config.load())?.validated().0
        }
        if let st = DaemonStatus.load(), st.isFresh() {
            s.status = st
            s.battery = st.battery
            s.batteryError = st.batteryError
            s.lowPower = (st.lowpower.macosLowPowerBattery, st.lowpower.macosLowPowerAC)
        } else {
            do { s.battery = try Battery.read() } catch { s.batteryError = "\(error)" }
            s.lowPower = PowerSettings.lowPowerModes()
        }
        return s
    }

    /// The pause setting (falls back to the daemon's mode if the config is unreadable).
    var paused: Bool { config?.paused ?? (status?.mode == "paused") }
    /// The manual extreme LPM switch; the auto-trigger is separate.
    var extremeSwitch: Bool { config?.lowpower.enabled ?? (status?.lowpower.trigger == "manual") }

    /// e.g. "71% · 30.9°", plus "⏸" when paused, "E" when extreme LPM is applied, "⚠" when the daemon is not running.
    var title: String {
        var t = battery.map { "\($0.percent)% · \(String(format: "%.1f", $0.temperatureC))°" } ?? "Battery ?"
        if paused { t += " ⏸\u{FE0E}" }
        if status?.lowpower.active == true { t += " E" }
        if status == nil { t += " ⚠\u{FE0E}" }
        return t
    }

    /// The read-only lines at the top of the menu.
    var lines: [String] {
        var l: [String] = []
        if let st = status {
            if st.mode != "active" { l.append("Battery Tool: \(st.mode)") }
        } else {
            l.append("Battery Tool daemon not running")
        }
        if let b = battery {
            // Live battery current when the daemon reports it; ioreg's IsCharging lags 30–60 s.
            let charging = status?.batteryCurrentMA.map { $0 > 100 } ?? b.isCharging
            let state = charging ? "Charging" : b.externalConnected ? "Not charging (AC attached)" : "On battery"
            l.append("Battery: \(b.percent)% · \(state)")
            var temp = "Temperature: \(String(format: "%.1f", b.temperatureC)) °C"
            if let c = config { temp += " (heat limit \(String(format: "%g", c.heatGuard.limitC)) °C)" }
            l.append(temp)
        } else {
            l.append("Battery: unreadable (\((batteryError ?? "no data").prefix(80)))")
        }
        if let ch = status?.charging {
            let allowed = ch.reason == "charging allowed" ? "Allowed" : "Allowed (\(ch.reason))"
            l.append("Charging: " + (ch.inhibited ? "Paused by \(ch.reason)" : allowed))
        }
        l.append("Low Power Mode: battery \(onOff(lowPower.battery)) · AC \(onOff(lowPower.ac))")
        return l
    }

    /// Extreme LPM switch position: the manual setting (the auto-trigger shows in the detail line).
    var extremeOn: Bool { extremeSwitch }

    /// One line under the extreme LPM switch (menu row and Settings window).
    var extremeText: String {
        guard let st = status else { return "Battery Tool daemon not running" }
        let lp = st.lowpower
        if lp.active {
            let n = "\(lp.throttledCount) process\(lp.throttledCount == 1 ? "" : "es") on efficiency cores"
            if lp.trigger == "auto" && !extremeSwitch {
                let t = config.map { String(format: "%g", $0.lowpower.autoTrigger.tempC) } ?? "?"
                return "On via auto-trigger (battery ≥ \(t) °C) · \(lp.throttledCount) processes"
            }
            return "On · \(n)"
        }
        if extremeSwitch { return paused ? "On, but Battery Tool is paused" : "Turning on…" }
        return "Off"
    }

    private func onOff(_ v: Int?) -> String {
        guard let v else { return "?" }
        return v == 0 ? "Off" : v == 1 ? "On" : "\(v)"
    }
}

/// osascript arguments that run the uninstall script as root after a password prompt. The path is
/// passed as an argument and shell-quoted by AppleScript (`quoted form of`), so spaces and quotes are safe.
func uninstallArguments(script: String) -> [String] {
    ["-e", "on run argv",
     "-e", "do shell script \"/bin/bash \" & quoted form of (item 1 of argv) & \" --from-menubar 2>&1\" "
         + "with prompt \"Battery Tool needs your password to restore normal charging and uninstall.\" "
         + "with administrator privileges without altering line endings",
     "-e", "end run", script]
}

/// osascript error -128: the user cancelled the password prompt, so nothing ran.
func isUserCancel(_ r: ShellResult) -> Bool {
    r.stderr.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("(-128)")
}

/// Output of a failed `do shell script`, which osascript reports as "N:M: execution error: <output> (<status>)".
func errorText(_ r: ShellResult) -> String {
    var s = r.stdout + r.stderr
    if let p = s.range(of: #"^\d+:\d+: execution error: "#, options: .regularExpression) { s.removeSubrange(p) }
    return s
}

/// The last `n` lines of command output, for alerts.
func tail(_ text: String, _ n: Int = 25) -> String {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? "(no output)" : t.components(separatedBy: "\n").suffix(n).joined(separator: "\n")
}

/// A menu row with a real on/off switch, so extreme low power mode is one click away.
final class SwitchRowView: NSView {
    private let title = NSTextField(labelWithString: "Extreme Low Power Mode")
    private let detail = NSTextField(labelWithString: "")
    private let toggle = NSSwitch()
    var onChange: ((Bool) -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 46))
        autoresizingMask = [.width]
        title.font = .menuFont(ofSize: 0)
        detail.font = .menuFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toggle.target = self
        toggle.action = #selector(flipped)
        toggle.setAccessibilityLabel("Extreme Low Power Mode")
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        for v in [text, toggle] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -12),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(on: Bool, detail text: String, enabled: Bool) {
        toggle.state = on ? .on : .off
        toggle.isEnabled = enabled
        detail.stringValue = text
    }

    @objc private func flipped() { onChange?(toggle.state == .on) }
}

final class MenuController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let extremeRow = SwitchRowView()
    /// Items disabled while a command runs (the menu may stay open after a switch click).
    private var busyItems: [NSMenuItem] = []
    private let settings = SettingsWindowController()
    private var snapshot = Snapshot()
    private var refreshing = false
    private var refreshAgain = false
    /// Shown in the menu while an action runs; actions (and Quit) are disabled meanwhile.
    private var busy: String?
    /// The extreme LPM switch position just requested, shown until a refresh reports the result.
    private var pendingExtreme: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "…"
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        extremeRow.onChange = { [weak self] on in self?.setExtreme(on) }
        settings.model.setExtreme = { [weak self] on in self?.setExtreme(on) }
        installMainMenu()
        // .common so the title keeps updating while the menu or an alert is open.
        let timer = Timer(timeInterval: 5, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        refresh()
    }

    /// Re-reads everything off the main thread, then updates the title, switch and Settings window.
    @objc private func refresh() {
        guard !refreshing else {
            refreshAgain = true
            return
        }
        refreshing = true
        DispatchQueue.global().async {
            let s = Snapshot.read()
            DispatchQueue.main.async {
                self.snapshot = s
                self.refreshing = false
                if self.busy == nil { self.pendingExtreme = nil }
                self.statusItem.button?.title = s.title
                self.updateLive()
                if self.refreshAgain {
                    self.refreshAgain = false
                    self.refresh()
                }
            }
        }
    }

    /// Pushes the extreme LPM state into the menu row and the Settings window.
    private func updateLive() {
        let s = snapshot
        let on = pendingExtreme ?? s.extremeOn
        let text = pendingExtreme.map { $0 ? "Turning on…" : "Turning off…" } ?? s.extremeText
        extremeRow.update(on: on, detail: text, enabled: busy == nil && s.status != nil)
        busyItems.forEach { $0.isEnabled = busy == nil }
        settings.model.update(LiveState(daemonRunning: s.status != nil, extremeOn: on, extremeText: text,
                                        actionRunning: busy != nil))
    }

    /// Rebuilt each time the menu opens (never while it is open, so items don't shift under the cursor).
    func menuNeedsUpdate(_ menu: NSMenu) {
        let s = snapshot
        menu.removeAllItems()
        for line in s.lines + [busy].compactMap({ $0 }) {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        // Title + action for VoiceOver and keyboard selection; the view draws the switch.
        let row = NSMenuItem(title: "Extreme Low Power Mode", action: #selector(toggleExtreme), keyEquivalent: "")
        row.target = self
        row.view = extremeRow
        menu.addItem(row)
        menu.addItem(.separator())
        busyItems = []
        add(s.paused ? "Resume Battery Tool" : "Pause Battery Tool", #selector(runCommand(_:)),
            command: [s.paused ? "resume" : "pause"])
        add("Settings…", #selector(openSettings), key: ",", alwaysEnabled: true)
        add("About Extreme Low Power Mode…", #selector(aboutExtreme), alwaysEnabled: true)
        add("Open Log", #selector(openLog), alwaysEnabled: true)
        menu.addItem(.separator())
        add("Uninstall and Restore Normal Charging…", #selector(uninstall))
        add("Quit Battery Tool Menu", #selector(quit))
        updateLive()
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, command: [String]? = nil, key: String = "",
                     alwaysEnabled: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.representedObject = command
        item.isEnabled = alwaysEnabled || busy == nil
        if !alwaysEnabled { busyItems.append(item) }
        menu.addItem(item)
        return item
    }

    /// Text fields in the Settings window need Edit shortcuts, and ⌘W closes it; an accessory app has no
    /// visible menu bar, but key equivalents still go through the main menu.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(appItem)
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    // MARK: - Actions

    /// Menu items that carry a `battery-tool` command (Pause / Resume).
    @objc private func runCommand(_ sender: NSMenuItem) {
        guard let args = sender.representedObject as? [String] else { return }
        run(args)
    }

    /// The extreme LPM switch (menu row and Settings window): one click, applied at once.
    private func setExtreme(_ on: Bool) {
        guard busy == nil else {
            updateLive()                       // snap the switch back; another action is running
            return
        }
        pendingExtreme = on
        run(["lowpower", on ? "on" : "off"])
    }

    /// Runs `battery-tool <args>` off the main thread (the CLI waits up to ~15 s for the daemon to
    /// apply the change), shows failures, and refreshes afterwards.
    private func run(_ args: [String]) {
        guard busy == nil else { return }
        let command = "battery-tool " + args.joined(separator: " ")
        busy = "Running \(command)…"
        updateLive()
        DispatchQueue.global().async {
            let r = Shell.run(Paths.binary, args, timeout: 60)
            DispatchQueue.main.async {
                self.busy = nil
                if !r.ok {
                    self.pendingExtreme = nil
                    self.showAlert("\(command) failed", r.timedOut ? "Timed out." : tail(r.stdout + r.stderr),
                                   style: .warning)
                }
                self.refresh()
            }
        }
    }

    /// Keyboard / VoiceOver activation of the switch row.
    @objc private func toggleExtreme() { setExtreme(!(pendingExtreme ?? snapshot.extremeOn)) }

    @objc private func openSettings() { settings.show() }

    @objc private func aboutExtreme() {
        showAlert("About Extreme Low Power Mode", """
            Extreme Low Power Mode approximates running on the efficiency cores only: it runs your apps at \
            background QoS (taskpolicy -b), which keeps their work on the efficiency cores, and turns on \
            macOS Low Power Mode.

            macOS does not allow disabling the performance cores on Apple Silicon. System processes, \
            protected apps and the frontmost app keep full speed and can still use them.

            Battery Tool restores the original priorities and Low Power Mode settings when it is turned \
            off, paused or uninstalled.
            """)
    }

    @objc private func openLog() {
        let url = URL(fileURLWithPath: Paths.logFile)
        if !FileManager.default.fileExists(atPath: url.path) || !NSWorkspace.shared.open(url) {
            showAlert("Cannot open the log", "\(Paths.logFile) does not exist or cannot be opened.", style: .warning)
        }
    }

    @objc private func uninstall() {
        guard busy == nil else { return }
        let confirm = NSAlert()
        confirm.alertStyle = .warning
        confirm.messageText = "Uninstall Battery Tool?"
        confirm.informativeText = "This re-enables normal charging, restores Low Power Mode and process priorities, "
            + "and removes Battery Tool completely."
        confirm.addButton(withTitle: "Uninstall").hasDestructiveAction = true
        confirm.addButton(withTitle: "Cancel")
        activate()
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        // Prefer the installed script; fall back to the copy inside this app bundle.
        let candidates = [Paths.uninstallScript, Bundle.main.path(forResource: "uninstall", ofType: "sh")]
        guard let script = candidates.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0) })
        else {
            showAlert("Uninstall script not found",
                      "Neither \(Paths.uninstallScript) nor this app's Resources/uninstall.sh exists.", style: .critical)
            return
        }
        busy = "Uninstalling…"
        DispatchQueue.global().async {
            // Generous timeout: the password prompt waits for the user.
            let r = Shell.run("/usr/bin/osascript", uninstallArguments(script: script), timeout: 1800)
            DispatchQueue.main.async { self.uninstallFinished(r) }
        }
    }

    private func uninstallFinished(_ r: ShellResult) {
        if r.ok {
            busy = "Uninstalled. Quitting…"
            showAlert("Battery Tool was uninstalled", tail(r.stdout))
            // Remove our own LaunchAgent job; launchd usually SIGTERMs us right away. Otherwise quit once
            // launchctl returns (at most 5 s).
            DispatchQueue.global().async {
                Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(Paths.menuLabel)"], timeout: 5)
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
            return
        }
        busy = nil
        if isUserCancel(r) {
            showAlert("Uninstall cancelled", "Nothing was changed.")
        } else {
            showAlert("Uninstall did not complete successfully",
                      r.timedOut ? "Timed out waiting for the uninstaller." : tail(errorText(r)), style: .critical)
        }
        refresh()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func showAlert(_ title: String, _ text: String, style: NSAlert.Style = .informational) {
        let a = NSAlert()
        a.alertStyle = style
        a.messageText = title
        a.informativeText = text
        activate()
        a.runModal()
    }

    /// Accessory apps must activate for alerts to come to the front.
    private func activate() {
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let controller = MenuController()   // NSApp.delegate is weak; this global keeps it alive.
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
