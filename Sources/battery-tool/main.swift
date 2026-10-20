import Foundation

// Entry point. `daemon` (started by launchd) and `selftest` are internal; every
// other command is the CLI (CLI.swift).
switch CommandLine.arguments.dropFirst().first ?? "" {
case "daemon":
    Daemon.run()
case "selftest":
    exit(SelfTest.run())
default:
    exit(CLI.run(Array(CommandLine.arguments.dropFirst())))
}
