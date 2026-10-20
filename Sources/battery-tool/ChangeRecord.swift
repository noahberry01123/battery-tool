import Foundation

/// Write-ahead record of every change extreme low power mode makes, so the next
/// daemon run or uninstall.sh (bash) can undo it. Lives at Paths.changeRecord
/// (root, 0644) and is rewritten atomically BEFORE each change. TAB-separated,
/// '#' comments; unknown or malformed lines are ignored:
///   lpm   battery|ac  <original lowpowermode>
///   since <epoch seconds extreme LPM was turned on>  (children started earlier did not inherit from us)
///   proc  <pid>  <start_sec>  <priority>  <nice>  <inherited 0|1>  <executable path (rest of line)>
struct ChangeRecord: Equatable {
    struct Proc: Equatable {
        var pid: Int32
        var startSec: UInt64        // with pid, identifies the process (pids are reused)
        var priority: Int32         // original values, informational
        var nice: Int32
        var inherited: Bool         // darwin-bg inherited from a throttled parent (no taskpolicy call)
        var path: String            // informational
    }

    /// Original macOS Low Power Mode, only for the power sources we changed.
    var lpmBattery: Int?
    var lpmAC: Int?
    var since: UInt64?
    var procs: [Proc] = []

    static let header = "# battery-tool change record v1 — used to restore settings; do not edit"

    var isEmpty: Bool { lpmBattery == nil && lpmAC == nil && procs.isEmpty }

    func serialized() -> String {
        var lines = [ChangeRecord.header]
        if let v = lpmBattery { lines.append("lpm\tbattery\t\(v)") }
        if let v = lpmAC { lines.append("lpm\tac\t\(v)") }
        if let v = since { lines.append("since\t\(v)") }
        for p in procs {
            // A newline would split the line; the path is informational, so mask it.
            let path = p.path.replacingOccurrences(of: "\n", with: "?").replacingOccurrences(of: "\r", with: "?")
            lines.append("proc\t\(p.pid)\t\(p.startSec)\t\(p.priority)\t\(p.nice)\t\(p.inherited ? 1 : 0)\t\(path)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func parse(_ text: String) -> ChangeRecord {
        var r = ChangeRecord()
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let f = line.split(separator: "\t", maxSplits: 6, omittingEmptySubsequences: false).map(String.init)
            if f.count == 3, f[0] == "lpm", let v = Int(f[2]), v >= 0 {
                // Keep the first (oldest) original per source.
                if f[1] == "battery" { r.lpmBattery = r.lpmBattery ?? v } else if f[1] == "ac" { r.lpmAC = r.lpmAC ?? v }
            } else if f.count == 2, f[0] == "since", let v = UInt64(f[1]) {
                r.since = r.since ?? v
            } else if f.count == 7, f[0] == "proc", let pid = Int32(f[1]), pid > 1, let start = UInt64(f[2]),
                      let priority = Int32(f[3]), let nice = Int32(f[4]), f[5] == "0" || f[5] == "1" {
                r.procs.append(Proc(pid: pid, startSec: start, priority: priority, nice: nice,
                                    inherited: f[5] == "1", path: f[6]))
            }
        }
        return r
    }

    /// nil if there is no record file.
    static func load(path: String) -> ChangeRecord? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// Atomic replace: temp file in the same directory, renamed; mode 0644. While it holds Low Power
    /// Mode originals (the only thing that matters after a power loss) the file and the rename are
    /// flushed to disk; `durable` forces that too.
    func save(path: String, durable: Bool = false) -> Bool {
        let durable = durable || lpmBattery != nil || lpmAC != nil
        let tmp = path + ".tmp"
        let bytes = Array(serialized().utf8)
        unlink(tmp)
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return false }
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        if durable && fcntl(fd, F_FULLFSYNC) != 0 { fsync(fd) }
        let ok = written == bytes.count && fchmod(fd, 0o644) == 0
        close(fd)
        guard ok, rename(tmp, path) == 0 else {
            unlink(tmp)
            return false
        }
        if durable {
            let dir = open((path as NSString).deletingLastPathComponent, O_RDONLY | O_CLOEXEC)
            if dir >= 0 {
                if fcntl(dir, F_FULLFSYNC) != 0 { fsync(dir) }
                close(dir)
            }
        }
        return true
    }

    /// True if the record file is gone afterwards.
    @discardableResult
    static func remove(path: String) -> Bool { unlink(path) == 0 || errno == ENOENT }
}

extension ChangeRecord.Proc {
    init(_ p: ProcInfo, inherited: Bool) {
        self.init(pid: p.pid, startSec: p.startSec, priority: p.priority, nice: p.nice, inherited: inherited, path: p.path)
    }
}
