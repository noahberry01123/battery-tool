import Foundation
import SystemConfiguration

struct ConsoleUser: Equatable {
    let name: String
    let uid: uid_t
    let home: String
}

enum Console {
    /// The user logged in at the GUI console, or nil at the login window.
    static func currentUser() -> ConsoleUser? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard let cf = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) else { return nil }
        let name = cf as String
        guard !name.isEmpty, name != "loginwindow", uid != 0 else { return nil }
        guard let home = homeDirectory(uid: uid) else { return nil }
        return ConsoleUser(name: name, uid: uid, home: home)
    }

    static func homeDirectory(uid: uid_t) -> String? {
        guard let pw = getpwuid(uid), let dir = pw.pointee.pw_dir else { return nil }
        return String(cString: dir)
    }
}

/// install-manifest.txt written by install.sh: `key=value` lines, e.g.
///   version=1.0.0  user=<user>  uid=<uid>  home=/Users/<user>  created_dir=/usr/local/var
enum InstallManifest {
    static func read(path: String = Paths.installManifest) -> [(key: String, value: String)] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { return nil }
            return (String(line[..<eq]), String(line[line.index(after: eq)...]))
        }
    }

    static func value(_ key: String) -> String? { read().first(where: { $0.key == key })?.value }
}

/// Current macOS build (e.g. "25G83"); SMC key verification is keyed to it.
enum OSInfo {
    static var build: String {
        let s = ProcessInfo.processInfo.operatingSystemVersionString   // "Version 26.6.2 (Build 25G83)"
        if let r = s.range(of: "Build ") { return String(s[r.upperBound...].prefix(while: { $0 != ")" })) }
        return s
    }
}
