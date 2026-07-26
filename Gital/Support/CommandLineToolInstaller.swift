import Foundation

/// Installs the `gital` command-line tool into /usr/local/bin, VSCode-style.
/// The installed script is self-contained and launches the app through
/// LaunchServices by bundle identifier, so it keeps working if the app moves.
enum CommandLineToolInstaller {
    static let installPath = "/usr/local/bin/gital"

    struct InstallError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let script = """
    #!/bin/sh
    # Opens a directory in Gital.app.
    # Installed by Gital > File > Install 'gital' Command-Line Tool.
    target="${1:-.}"
    case "$target" in
        /*) ;;
        *) target="$PWD/$target" ;;
    esac
    exec open -b app.kymmt.Gital "$target"

    """

    static func install() async throws {
        if installDirectly() { return }
        try await installWithAdministratorPrivileges()
    }

    /// Succeeds when /usr/local/bin already exists and is writable by the user
    /// (common on Intel Macs with Homebrew).
    private static func installDirectly() -> Bool {
        FileManager.default.createFile(
            atPath: installPath,
            contents: Data(script.utf8),
            attributes: [.posixPermissions: 0o755]
        )
    }

    private static func installWithAdministratorPrivileges() async throws {
        let stagingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gital-cli-\(ProcessInfo.processInfo.processIdentifier)")
        try Data(script.utf8).write(to: stagingURL)
        defer { try? FileManager.default.removeItem(at: stagingURL) }

        let shellCommand =
            "mkdir -p /usr/local/bin && install -m 755 '\(stagingURL.path)' '\(installPath)'"
        let appleScript = "do shell script \"\(shellCommand)\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()
        let stderrData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume() }
        }

        guard process.terminationStatus == 0 else {
            let stderr = String(decoding: stderrData, as: UTF8.self)
            if stderr.contains("-128") {  // user cancelled the password prompt
                throw InstallError(message: "Installation was cancelled.")
            }
            throw InstallError(
                message: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
