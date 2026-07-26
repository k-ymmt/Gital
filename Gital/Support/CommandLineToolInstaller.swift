import Foundation

/// Installs the `gital` command-line tool into /usr/local/bin, VSCode-style.
/// The script prefers the exact app copy that installed it — with several
/// copies on disk (e.g. DerivedData debug builds), `open -b` may launch a
/// stale one — and falls back to the bundle identifier if the app has moved.
enum CommandLineToolInstaller {
    static let installPath = "/usr/local/bin/gital"

    /// Present in every script this installer writes; lets a reinstall
    /// distinguish our own tool from an unrelated `gital` already in PATH.
    private static let marker = "# Installed by Gital.app"

    struct InstallError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func script(appPath: String) -> String {
        """
        #!/bin/sh
        \(marker) — File > Install “gital” Command-Line Tool.
        # Opens a directory (default: the current one) in Gital.
        app_path=\(shellSingleQuoted(appPath))

        case "$1" in
            -h|--help)
                echo "usage: gital [directory]"
                exit 0
                ;;
        esac

        target="${1:-.}"
        case "$target" in
            /*) ;;
            *) target="$PWD/$target" ;;
        esac

        if [ -d "$app_path" ]; then
            exec open -a "$app_path" "$target"
        fi
        exec open -b app.kymmt.Gital "$target"

        """
    }

    static func install() async throws {
        try ensureNotForeignTool()
        let script = script(appPath: Bundle.main.bundleURL.path)
        if installDirectly(script) { return }
        try await installWithAdministratorPrivileges(script)
    }

    private static func ensureNotForeignTool() throws {
        guard FileManager.default.fileExists(atPath: installPath) else { return }
        let contents = (try? String(contentsOfFile: installPath, encoding: .utf8)) ?? ""
        guard contents.contains(marker) else {
            throw InstallError(
                message: "\(installPath) already exists and was not installed by Gital. "
                    + "Remove it manually, then try again.")
        }
    }

    /// Succeeds when /usr/local/bin already exists and is writable by the user
    /// (common on Intel Macs with Homebrew).
    private static func installDirectly(_ script: String) -> Bool {
        FileManager.default.createFile(
            atPath: installPath,
            contents: Data(script.utf8),
            attributes: [.posixPermissions: 0o755]
        )
    }

    private static func installWithAdministratorPrivileges(_ script: String) async throws {
        let stagingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gital-cli-\(ProcessInfo.processInfo.processIdentifier)")
        try Data(script.utf8).write(to: stagingURL)
        defer { try? FileManager.default.removeItem(at: stagingURL) }

        let appleScript = "do shell script \"mkdir -p /usr/local/bin && install -m 755 \""
            + " & quoted form of \(appleScriptLiteral(stagingURL.path))"
            + " & \" \" & quoted form of \(appleScriptLiteral(installPath))"
            + " with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }

        guard process.terminationStatus == 0 else {
            let stderrData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
            let stderr = String(decoding: stderrData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if stderr.contains("(-128)") {  // user cancelled the password prompt
                throw InstallError(message: "Installation was cancelled.")
            }
            throw InstallError(
                message: stderr.isEmpty
                    ? "The install helper exited with status \(process.terminationStatus)."
                    : stderr)
        }
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptLiteral(_ value: String) -> String {
        "\""
            + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            + "\""
    }
}
