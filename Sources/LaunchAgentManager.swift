import Darwin
import Foundation

/// Manages a per-user macOS LaunchAgent that launches ContextRing when Antigravity starts
/// without keeping ContextRing running in the background while Antigravity is closed.
enum LaunchAgentManager {
    static let label = "com.vladsboev.contextring.autolaunch"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func install(appBundlePath: String, onlyIfChanged: Bool = false) throws {
        let plistData = try buildPlistData(appBundlePath: appBundlePath)
        let url = plistURL

        if onlyIfChanged, let existing = try? Data(contentsOf: url), existing == plistData {
            return
        }

        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try plistData.write(to: url, options: [.atomic])

        let uid = getuid()
        _ = runLaunchctl(["bootout", "gui/\(uid)/\(label)"])

        let boot = runLaunchctl(["bootstrap", "gui/\(uid)", url.path])
        if boot.status != 0 {
            let legacy = runLaunchctl(["load", "-w", url.path])
            if legacy.status != 0 {
                let reason = !boot.stderr.isEmpty ? boot.stderr : legacy.stderr
                throw NSError(
                    domain: label,
                    code: Int(legacy.status),
                    userInfo: [NSLocalizedDescriptionKey: reason.isEmpty ? "launchctl failed" : reason]
                )
            }
        }
    }

    static func uninstall() {
        let uid = getuid()
        _ = runLaunchctl(["bootout", "gui/\(uid)/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    private static func buildPlistData(appBundlePath: String) throws -> Data {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let supportDir = "\(home)/Library/Application Support/Antigravity"
        let escapedBundle = appBundlePath.replacingOccurrences(of: "'", with: "'\\''")

        let shellScript = """
        if /usr/bin/lsappinfo find bundleid=com.google.antigravity 2>/dev/null | /usr/bin/grep -q '^ASN:' && ! /usr/bin/lsappinfo find bundleid=com.vladsboev.contextring 2>/dev/null | /usr/bin/grep -q '^ASN:'; then
          APP='\(escapedBundle)'
          [ -d "$APP" ] || APP='/Applications/ContextRing.app'
          [ -d "$APP" ] && /usr/bin/open -g "$APP"
        fi
        """

        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/bin/sh", "-c", shellScript],
            "WatchPaths": [
                "\(supportDir)/SingletonLock",
                "\(supportDir)/window_state.json",
                "\(supportDir)/Preferences",
            ],
            "RunAtLoad": true,
            "ThrottleInterval": 5,
            "ProcessType": "Background",
        ]

        return try PropertyListSerialization.data(
            fromPropertyList: dict,
            format: .xml,
            options: 0
        )
    }

    private static func runLaunchctl(_ args: [String]) -> (status: Int32, stderr: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = args
        let errPipe = Pipe()
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = errPipe

        do {
            try proc.run()
            proc.waitUntilExit()
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (proc.terminationStatus, errText)
        } catch {
            return (-1, error.localizedDescription)
        }
    }
}
