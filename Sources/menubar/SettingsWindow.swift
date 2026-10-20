import AppKit
import SwiftUI

/// What the menu controller's 5-second refresh knows, pushed into the settings window.
struct LiveState {
    var daemonRunning = false
    var extremeOn = false          // manual switch on, or the mode currently active
    var extremeText = ""           // e.g. "On · 243 processes on efficiency cores"
    var actionRunning = false      // a battery-tool command from the menu is still running
}

/// Settings window state. Edits stay in `draft` until Apply; the extreme LPM switch acts at once
/// (it is runtime state, like the menu switch). Every file access runs off the main thread.
final class SettingsModel: ObservableObject {
    @Published var draft = Config()
    @Published private(set) var loaded = Config()
    @Published private(set) var message = ""
    @Published private(set) var isError = false
    @Published private(set) var saving = false
    @Published private(set) var live = LiveState()
    /// Turns extreme LPM on or off now (the menu controller runs `battery-tool lowpower on|off`).
    var setExtreme: (Bool) -> Void = { _ in }

    var hasChanges: Bool { Self.edits(draft) != Self.edits(loaded) }

    private static func edits(_ c: Config) -> Config { c.applyingEdits(onto: Config()) }

    /// Reads config.json, discarding unsaved edits.
    func load() {
        DispatchQueue.global().async {
            let r = Self.readConfig()
            DispatchQueue.main.async { self.show(config: r.config, error: r.error) }
        }
    }

    func show(config: Config, error: String?) {
        loaded = config
        draft = config
        message = error ?? ""
        isError = error != nil
    }

    func update(_ live: LiveState) { self.live = live }

    func restoreDefaults() {
        draft = Config().applyingEdits(onto: draft)
        message = "Defaults restored; press Apply to save them."
        isError = false
    }

    func revert() {
        draft = loaded
        message = ""
        isError = false
    }

    func apply() {
        guard !saving else { return }
        saving = true
        message = "Saving…"
        isError = false
        let edited = draft, original = loaded
        DispatchQueue.global().async {
            let r = Self.save(edited, since: original)
            DispatchQueue.main.async {
                self.saving = false
                self.message = r.message
                self.isError = r.saved == nil
                if let c = r.saved {
                    self.loaded = c
                    // Keep anything typed while the save was running.
                    if Self.edits(self.draft) == Self.edits(edited) { self.draft = c }
                }
            }
        }
    }

    /// The current config.json (defaults when missing). Only a regular file is read, so a FIFO
    /// planted in the admin-writable folder cannot hang the app.
    static func readConfig() -> (config: Config, error: String?) {
        var st = stat()
        if stat(Paths.configFile, &st) == 0 && st.st_mode & S_IFMT != S_IFREG {
            return (Config(), "config.json is not a regular file; Apply replaces it with these settings.")
        }
        if stat(Paths.configFile, &st) == 0 && access(Paths.configFile, R_OK) != 0 {
            return (Config(), "config.json cannot be read by this user; the values shown are the defaults.")
        }
        do {
            return (try Config.load().validated().0, nil)
        } catch {
            return (Config(), "config.json cannot be read (\(error)); Apply replaces it with these settings.")
        }
    }

    /// Copies the edited settings onto the file as it is NOW (so menu/CLI changes made meanwhile
    /// survive), saves, then waits up to 15 s for the daemon to apply it. Blocks; call off-main.
    static func save(_ edited: Config, since original: Config? = nil) -> (saved: Config?, message: String) {
        if access(Paths.configDir, W_OK | X_OK) != 0 {
            let err = errno
            switch err {
            case ENOENT: return (nil, "Battery Tool is not installed.")
            case EACCES, EPERM: return (nil, "Only administrator accounts can change Battery Tool settings.")
            default: return (nil, "Cannot write \(Paths.configDir): \(String(cString: strerror(err)))")
            }
        }
        let current = readConfig()
        var base = current.config
        if current.error != nil, let st = DaemonStatus.load() {
            // The file is unusable: keep the runtime state the daemon reports instead of the defaults.
            base.revision = max(base.revision, st.appliedConfigRevision)
            base.paused = st.mode == "paused"
            base.lowpower.enabled = st.lowpower.active && st.lowpower.trigger == "manual"
            base.probeRequest = st.probe?.request ?? base.probeRequest
        }
        let (merged, notes) = edited.applyingEdits(onto: base, since: original).validated()
        do {
            try merged.save()
        } catch {
            return (nil, "\(error)")
        }
        var parts: [String] = []
        if current.error != nil { parts.append("Replaced the unreadable config file.") }
        if !notes.isEmpty { parts.append("Adjusted: " + notes.joined(separator: "; ") + ".") }
        parts.append(waitForDaemon(merged.revision))
        if merged.paused { parts.append("Battery Tool is paused; these settings take effect when you resume it.") }
        return (merged, parts.joined(separator: " "))
    }

    private static func waitForDaemon(_ revision: Int) -> String {
        guard DaemonStatus.load()?.isFresh() == true else { return "Saved; it takes effect when the daemon runs." }
        let deadline = Date().addingTimeInterval(15)
        repeat {
            if let s = DaemonStatus.load(), s.appliedConfigRevision >= revision { return "Applied." }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return "Saved; the daemon has not applied it yet."
    }
}

/// Every config.json setting as a form. Ranges match Config.validated() and the CLI.
struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var newName = ""

    private var limit: Config.ChargeLimit { model.draft.chargeLimit }
    private var heat: Config.HeatGuard { model.draft.heatGuard }
    private var duty: Config.DutyCycle { model.draft.dutyCycle }
    private var auto: Config.LowPower.AutoTrigger { model.draft.lowpower.autoTrigger }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                chargingSection
                limitSection
                heatSection
                dutySection
                extremeSection
                protectedSection
                advancedSection
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
        .frame(width: 540)
        .frame(minHeight: 480)
    }

    // MARK: Sections

    private var chargingSection: some View {
        Section {
            Toggle("Manage charging", isOn: $model.draft.enabled)
        } footer: {
            caption(model.draft.enabled
                ? "The charge limit, heat guard and duty cycle below control charging."
                : "Off: the charge limit, heat guard and duty cycle are ignored and the Mac always charges.")
        }
    }

    private var limitSection: some View {
        Section {
            IntRow(label: "Stop charging at", value: $model.draft.chargeLimit.maxPercent, range: Config.maxPercentRange, unit: "%")
                .onChange(of: limit.maxPercent) { _, v in
                    if Config.maxPercentRange.contains(v) && limit.resumePercent >= v {
                        model.draft.chargeLimit.resumePercent = max(10, v - 1)
                    }
                }
            IntRow(label: "Resume charging at", value: $model.draft.chargeLimit.resumePercent,
                   range: 10...max(10, limit.maxPercent - 1), unit: "%")
                .disabled(limit.maxPercent >= 100)
        } header: {
            Text("Charge limit")
        } footer: {
            caption(limit.maxPercent >= 100
                ? "No charge limit: the battery charges to 100%."
                : "Charging pauses at \(limit.maxPercent)% and resumes when the battery drops to \(limit.resumePercent)%.")
        }
    }

    private var heatSection: some View {
        Section {
            DecimalRow(label: "Pause charging at", value: $model.draft.heatGuard.limitC, range: Config.heatLimitRange, unit: "°C")
        } header: {
            Text("Heat guard")
        } footer: {
            caption("Charging resumes at or below \(degrees(heat.resumeC)) (3 °C lower).")
        }
    }

    private var dutySection: some View {
        Section {
            Toggle("Charge in short bursts when warm", isOn: $model.draft.dutyCycle.enabled)
            Group {
                DecimalRow(label: "Start at", value: $model.draft.dutyCycle.warmC, range: 20...Config.heatLimitRange.upperBound,
                           unit: "°C")
                IntRow(label: "Charge for", value: $model.draft.dutyCycle.onSeconds, range: Config.dutySecondsRange, step: 5, unit: "s")
                IntRow(label: "Then pause for", value: $model.draft.dutyCycle.offSeconds, range: Config.dutySecondsRange, step: 5,
                       unit: "s")
            }
            .disabled(!duty.enabled)
        } header: {
            Text("Duty cycle")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                caption("Alternates charging on and off to approximate slower charging while the battery is warm.")
                if duty.enabled && duty.warmC >= heat.limitC {
                    warning("The start temperature must be below the heat-guard limit (\(degrees(heat.limitC))); "
                            + "otherwise the duty cycle never runs.")
                }
            }
        }
    }

    private var extremeSection: some View {
        Section {
            Toggle(isOn: Binding(get: { model.live.extremeOn }, set: { model.setExtreme($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Extreme Low Power Mode")
                    Text(model.live.extremeText).font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(model.live.actionRunning || !model.live.daemonRunning)
            caption("Approximates running on the efficiency cores only: your apps run at background priority "
                    + "(taskpolicy -b) and macOS Low Power Mode is turned on. macOS does not allow disabling the "
                    + "performance cores on Apple Silicon. This switch takes effect immediately.")
            Toggle("Turn on automatically when the battery is hot", isOn: $model.draft.lowpower.autoTrigger.enabled)
            DecimalRow(label: "Turn on at", value: $model.draft.lowpower.autoTrigger.tempC, range: Config.autoTriggerRange,
                       unit: "°C")
                .disabled(!auto.enabled)
        } footer: {
            caption("Turns off again at or below \(degrees(auto.releaseC)).")
        }
    }

    private var protectedSection: some View {
        Section {
            Toggle("Always protect the frontmost app", isOn: frontmost)
            ForEach(named, id: \.self) { name in
                HStack {
                    Text(name)
                    Spacer()
                    Button { remove(name) } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Remove \(name)")
                        .accessibilityLabel("Remove \(name)")
                }
            }
            HStack {
                TextField("Add an app", text: $newName, prompt: Text("App or process name"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .onSubmit { add(newName) }
                Button("Add") { add(newName) }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                Menu("Running Apps") {
                    ForEach(runningApps, id: \.self) { name in Button(name) { add(name) } }
                }
                .fixedSize()
            }
        } header: {
            Text("Protected apps")
        } footer: {
            caption("Extreme Low Power Mode never slows these down, including everything inside their .app bundle. "
                    + "Names match the app or process name, ignoring case.")
        }
    }

    private var advancedSection: some View {
        Section("Advanced") {
            IntRow(label: "Check the battery every", value: $model.draft.pollIntervalSeconds, range: Config.pollRange, unit: "s")
            IntRow(label: "Scan processes every", value: $model.draft.lowpower.scanIntervalSeconds,
                   range: Config.intervalRange, unit: "s")
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !model.message.isEmpty {
                Image(systemName: model.isError ? "exclamationmark.triangle.fill" : "info.circle")
                    .foregroundStyle(model.isError ? Color.orange : Color.secondary)
                Text(model.message)
                    .font(.callout)
                    .foregroundStyle(model.isError ? Color.primary : Color.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Restore Defaults") { model.restoreDefaults() }
            Button("Revert") { model.revert() }
                .disabled(!model.hasChanges || model.saving)
            Button("Apply") { model.apply() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.hasChanges || model.saving)
        }
        .padding(12)
    }

    // MARK: Protected list

    private var named: [String] {
        model.draft.lowpower.protected.filter { $0.lowercased() != Config.frontmostToken }
    }

    private var frontmost: Binding<Bool> {
        Binding(get: { model.draft.lowpower.protected.contains { $0.lowercased() == Config.frontmostToken } },
                set: { on in
                    model.draft.lowpower.protected.removeAll { $0.lowercased() == Config.frontmostToken }
                    if on { model.draft.lowpower.protected.append(Config.frontmostToken) }
                })
    }

    /// Regular (Dock) apps that are running and not listed yet.
    private var runningApps: [String] {
        let listed = Set(model.draft.lowpower.protected.map { $0.lowercased() })
        let names = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.localizedName)
            .filter { !listed.contains($0.lowercased()) }
        return Array(Set(names)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func add(_ raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        newName = ""
        guard !name.isEmpty, name.lowercased() != Config.frontmostToken,
              !model.draft.lowpower.protected.contains(where: { $0.lowercased() == name.lowercased() }) else { return }
        model.draft.lowpower.protected.append(name)
    }

    private func remove(_ name: String) {
        model.draft.lowpower.protected.removeAll { $0 == name }
    }

    // MARK: Helpers

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
    }

    private func degrees(_ v: Double) -> String { String(format: "%.1f °C", v) }
}

/// "Label …… [ 80 ] % [−|+]", clamped to `range`.
private struct IntRow: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    let unit: String

    var body: some View {
        // The field is written on every keystroke, so partial input is left alone here; Config.validated()
        // clamps on Apply and the window reports what it adjusted.
        LabeledContent(label) {
            HStack(spacing: 6) {
                TextField(label, value: $value, format: .number.grouping(.never))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                Text(unit).foregroundStyle(.secondary).frame(width: 22, alignment: .leading)
                Stepper(label, value: $value, in: range, step: step).labelsHidden()
            }
        }
    }
}

/// Like IntRow for temperatures: one decimal, steps of 0.5.
private struct DecimalRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String

    var body: some View {
        let finite = Binding<Double>(get: { value }, set: { if $0.isFinite { value = $0 } })   // "nan" parses
        LabeledContent(label) {
            HStack(spacing: 6) {
                TextField(label, value: finite, format: .number.precision(.fractionLength(0...1)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                Text(unit).foregroundStyle(.secondary).frame(width: 22, alignment: .leading)
                Stepper(label, value: finite, in: range, step: 0.5).labelsHidden()
            }
        }
    }
}

/// One settings window, reused; opened from the menu ("Settings…").
final class SettingsWindowController: NSObject, NSWindowDelegate {
    let model = SettingsModel()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            w.title = "Battery Tool Settings"
            w.styleMask = [.titled, .closable, .resizable]
            w.setContentSize(NSSize(width: 540, height: 700))
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        // Fresh values each time it opens; an already open window keeps its unsaved edits.
        if window?.isVisible != true { model.load() }
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        window?.makeKeyAndOrderFront(nil)
    }
}
