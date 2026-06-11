import AppKit
import Foundation

/// Brings the app hosting a session to the front. Terminal sessions jump to
/// the exact iTerm tab by matching the claude process's controlling tty;
/// desktop and VS Code sessions activate/open their windows.
enum SessionFocus {
    static func focus(_ session: Session) {
        Log.info("focus: pid=\(session.pid) via \(session.entrypoint.displayName)")
        switch session.entrypoint {
        case .claudeDesktop:
            activateApp(bundleIds: ["com.anthropic.claudefordesktop"], fallbackName: "Claude")
        case .claudeVscode:
            // Opening the workspace folder focuses (or restores) its window.
            runDetached("/usr/bin/open", ["-a", "Visual Studio Code", session.cwd])
        case .cli, .unknown:
            focusTerminal(session)
        }
    }

    private static func activateApp(bundleIds: [String], fallbackName: String) {
        for bundleId in bundleIds {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
                app.activate()
                return
            }
        }
        runDetached("/usr/bin/open", ["-a", fallbackName])
    }

    private static func focusTerminal(_ session: Session) {
        guard let tty = controllingTTY(of: session.pid) else {
            activateApp(bundleIds: ["com.googlecode.iterm2"], fallbackName: "iTerm")
            return
        }
        // First click prompts for Automation permission (ClaudeBar → iTerm).
        let script = """
        tell application "iTerm"
            activate
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    repeat with aSession in sessions of aTab
                        if tty of aSession ends with "\(tty)" then
                            select aWindow
                            tell aWindow to select aTab
                            select aSession
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
        runDetached("/usr/bin/osascript", ["-e", script])
    }

    /// "ttys012"-style controlling terminal of a pid, nil for daemons ("??").
    private static func controllingTTY(of pid: Int32) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "tty="]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let tty = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tty.isEmpty, tty != "??" else { return nil }
        return tty
    }

    private static func runDetached(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try? process.run()
    }
}
