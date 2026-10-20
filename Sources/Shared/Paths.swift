// Every file, directory and launchd label battery-tool owns. install.sh and
// uninstall.sh hard-code the same values; keep them in sync.
enum Paths {
    static let binary = "/usr/local/bin/battery-tool"

    static let libDir = "/usr/local/lib/battery-tool"
    static let smcHelper = libDir + "/smc-helper"
    static let uninstallScript = libDir + "/uninstall.sh"
    static let installManifest = libDir + "/install-manifest.txt"

    static let configDir = "/usr/local/etc/battery-tool"   // root:admin 0775
    static let configFile = configDir + "/config.json"     // admin-writable 0664

    static let varDir = "/usr/local/var/battery-tool"      // root-only state
    static let stateFile = varDir + "/state.json"
    static let policyFile = varDir + "/policy.json"       // charge-limit / heat holds across restarts
    static let statusFile = varDir + "/status.json"
    static let changeRecord = varDir + "/changes.tsv"
    static let lockFile = varDir + "/daemon.lock"
    static let logDir = varDir + "/log"
    static let logFile = logDir + "/battery-tool.log"
    static let daemonOutLog = logDir + "/daemon.out.log"   // launchd stdout/stderr

    static let daemonLabel = "local.battery-tool.daemon"
    static let daemonPlist = "/Library/LaunchDaemons/local.battery-tool.daemon.plist"
    static let menuLabel = "local.battery-tool.menubar"
    static let menuPlist = "/Library/LaunchAgents/local.battery-tool.menubar.plist"
    static let menuApp = "/Applications/BatteryTool.app"
    static let menuAppUninstallScript = menuApp + "/Contents/Resources/uninstall.sh"

    /// Created on the user's Desktop to force a full uninstall.
    static let sentinelName = "UNINSTALL-BATTERY-TOOL"

    static let version = "1.0.0"
}
