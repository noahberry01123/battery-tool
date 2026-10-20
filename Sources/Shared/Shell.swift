import Foundation

struct ShellResult {
    var status: Int32
    var stdout: String
    var stderr: String
    var timedOut = false
    var ok: Bool { status == 0 && !timedOut }
}

enum Shell {
    /// Runs an absolute-path executable directly (no shell, no PATH lookup) with a
    /// fixed C-locale environment so tool output parses predictably.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String] = [], timeout: TimeInterval = 20) -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "LANG": "C"]
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err

        let box = OutputBox()
        let readers = DispatchGroup()
        for (pipe, isOut) in [(out, true), (err, false)] {
            readers.enter()
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                box.set(data, isOut: isOut)
                readers.leave()
            }
        }
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do {
            try p.run()
        } catch {
            // Close our write ends so the readers finish.
            try? out.fileHandleForWriting.close()
            try? err.fileHandleForWriting.close()
            return ShellResult(status: -1, stdout: "", stderr: "failed to launch \(executable): \(error)")
        }
        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                exited.wait()
            }
        }
        // Grandchildren could keep the pipes open; don't wait on them forever.
        _ = readers.wait(timeout: .now() + 2)
        let (o, e) = box.get()
        return ShellResult(status: p.terminationStatus,
                           stdout: String(decoding: o, as: UTF8.self),
                           stderr: String(decoding: e, as: UTF8.self),
                           timedOut: timedOut)
    }

    private final class OutputBox {
        private let lock = NSLock()
        private var out = Data(), err = Data()
        func set(_ d: Data, isOut: Bool) { lock.lock(); if isOut { out = d } else { err = d }; lock.unlock() }
        func get() -> (Data, Data) { lock.lock(); defer { lock.unlock() }; return (out, err) }
    }
}
