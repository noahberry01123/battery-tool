import Foundation

/// Append-only log with size-based rotation: battery-tool.log, .1 … .(keep-1).
/// Falls back to stderr if the file cannot be opened (e.g. CLI without root).
final class Logger {
    static let shared = Logger(path: Paths.logFile)

    private let path: String
    private let maxBytes: Int
    private let keep: Int
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var size = 0
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f
    }()
    /// Mirror every line to stderr (set when running in the foreground).
    var alsoStderr = false

    init(path: String, maxBytes: Int = 1_000_000, keep: Int = 5) {
        self.path = path
        self.maxBytes = maxBytes
        self.keep = max(2, keep)
    }

    func info(_ message: String) { write("INFO", message) }
    func warn(_ message: String) { write("WARN", message) }
    func error(_ message: String) { write("ERROR", message) }

    private func write(_ level: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
        let bytes = Array(line.utf8)
        if fd < 0 { openFile() }
        if fd >= 0 && size + bytes.count > maxBytes { rotate() }
        if fd >= 0 {
            bytes.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress, $0.count) }
            size += bytes.count
        }
        if alsoStderr || fd < 0 { FileHandle.standardError.write(Data(bytes)) }
    }

    private func openFile() {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o755])
        fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        var st = stat()
        size = (fd >= 0 && fstat(fd, &st) == 0) ? Int(st.st_size) : 0
    }

    private func rotate() {
        close(fd)
        fd = -1
        unlink("\(path).\(keep - 1)")
        for i in stride(from: keep - 2, through: 1, by: -1) { rename("\(path).\(i)", "\(path).\(i + 1)") }
        rename(path, "\(path).1")
        openFile()
    }
}
