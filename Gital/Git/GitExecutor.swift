import Foundation

struct GitError: LocalizedError {
    let command: String
    let exitCode: Int32
    let stderr: String

    var errorDescription: String? {
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "git \(command) failed (exit \(exitCode))" : message
    }
}

/// Runs git as a subprocess against a repository working directory.
actor GitExecutor {
    let workingDirectory: URL

    init(workingDirectory: URL) {
        self.workingDirectory = workingDirectory
    }

    @discardableResult
    func run(_ arguments: [String], successCodes: Set<Int32> = [0]) async throws -> String {
        let data = try await runData(arguments, successCodes: successCodes)
        return String(decoding: data, as: UTF8.self)
    }

    func runData(_ arguments: [String], successCodes: Set<Int32> = [0]) async throws -> Data {
        let workingDirectory = self.workingDirectory
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                // quotepath=false keeps non-ASCII paths raw in diff/log output
                // instead of C-quoted octal escapes.
                process.arguments = ["git", "--no-optional-locks", "-c", "color.ui=false", "-c", "core.quotepath=false"] + arguments
                process.currentDirectoryURL = workingDirectory

                var environment = ProcessInfo.processInfo.environment
                environment["GIT_TERMINAL_PROMPT"] = "0"
                environment["LC_ALL"] = "en_US.UTF-8"
                process.environment = environment

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                if successCodes.contains(process.terminationStatus) {
                    continuation.resume(returning: stdout)
                } else {
                    continuation.resume(throwing: GitError(
                        command: arguments.joined(separator: " "),
                        exitCode: process.terminationStatus,
                        stderr: String(decoding: stderr, as: UTF8.self)
                    ))
                }
            }
        }
    }
}
