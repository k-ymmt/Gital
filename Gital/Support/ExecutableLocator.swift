import Foundation

/// Locates CLI tools (`gh`, `codex`, …) for a GUI app whose environment PATH
/// lacks the user's shell setup. Tools are then executed directly — running
/// them through `zsh -lc` would let login-profile output (nvm banners etc.)
/// pollute stdout and corrupt JSON/protocol streams.
nonisolated final class ExecutableLocator: @unchecked Sendable {
    static let shared = ExecutableLocator()

    private let lock = NSLock()
    private var cache: [String: URL] = [:]

    func find(_ name: String) -> URL? {
        lock.lock()
        if let hit = cache[name] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        var directories: [String] = []
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            directories += path.split(separator: ":").map(String.init)
        }
        directories += [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            NSHomeDirectory() + "/.local/bin",
            NSHomeDirectory() + "/bin",
        ]

        let fileManager = FileManager.default
        var found: URL?
        for directory in directories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                found = candidate
                break
            }
        }
        if found == nil {
            found = loginShellLookup(name)
        }
        if let found {
            lock.lock()
            cache[name] = found
            lock.unlock()
        }
        return found
    }

    /// Last resort: ask a login shell where the tool lives. Only a verified
    /// executable path is taken from the output — profiles may print noise.
    private func loginShellLookup(_ name: String) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v -- " + name]
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        // `terminationHandler` instead of `waitUntilExit`: the latter polls the
        // current thread's run loop and can miss the termination notification
        // on a GCD/concurrency worker thread, hanging after the shell exited.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        guard (try? process.run()) != nil else {
            process.terminationHandler = nil
            return nil
        }
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        exited.wait()

        let fileManager = FileManager.default
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed() {
            let candidate = String(line).trimmingCharacters(in: .whitespaces)
            if candidate.hasPrefix("/"), fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }
}
