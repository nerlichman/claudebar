import Foundation

/// Installs the Claude Code integration bundled with the app: copies the
/// hook scripts into Application Support and registers them in
/// ~/.claude/settings.json (statusline capture + lifecycle events).
/// Idempotent, never removes existing entries, and preserves a pre-existing
/// statusline command by saving it for the hook script to delegate to.
enum HookInstaller {
    private static let supportDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ClaudeBar", isDirectory: true)
    private static let settingsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")
    private static let scriptNames = ["statusline-hook.sh", "claudebar-hook.sh"]
    private static let statuslineCommand =
        "bash \"$HOME/Library/Application Support/ClaudeBar/statusline-hook.sh\""
    private static let lifecycleEvents: [(event: String, arg: String)] = [
        ("SessionStart", "start"),
        ("UserPromptSubmit", "prompt"),
        ("Stop", "stop"),
        ("Notification", "notification"),
        ("SessionEnd", "end"),
    ]

    static var isInstalled: Bool {
        let fm = FileManager.default
        guard scriptNames.allSatisfy({
            fm.fileExists(atPath: supportDir.appendingPathComponent($0).path)
        }) else { return false }
        guard let json = readSettings() else { return false }
        let statusLine = (json["statusLine"] as? [String: Any])?["command"] as? String ?? ""
        guard statusLine.contains("statusline-hook.sh") else { return false }
        let hooks = json["hooks"] as? [String: Any] ?? [:]
        return lifecycleEvents.allSatisfy { registered(in: hooks, event: $0.event) }
    }

    static func install() throws {
        try copyBundledScripts()
        try registerInSettings()
        Log.info("hooks: installed (scripts + settings.json registration)")
    }

    // MARK: - Scripts

    private static func copyBundledScripts() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        for name in scriptNames {
            guard let bundled = Bundle.main.url(forResource: name, withExtension: nil) else {
                throw NSError(domain: "ClaudeBar", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "\(name) missing from app bundle",
                ])
            }
            let dest = supportDir.appendingPathComponent(name)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: bundled, to: dest)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        }
    }

    // MARK: - settings.json

    private static func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func registered(in hooks: [String: Any], event: String) -> Bool {
        let entries = hooks[event] as? [[String: Any]] ?? []
        return entries.contains { entry in
            ((entry["hooks"] as? [[String: Any]]) ?? []).contains {
                ($0["command"] as? String)?.contains("claudebar-hook.sh") == true
            }
        }
    }

    private static func registerInSettings() throws {
        var json = readSettings() ?? [:]

        // One-time backup before our first write, kept forever.
        let backup = settingsURL.appendingPathExtension("claudebar-backup")
        let fm = FileManager.default
        if fm.fileExists(atPath: settingsURL.path), !fm.fileExists(atPath: backup.path) {
            try? fm.copyItem(at: settingsURL, to: backup)
        }

        // A pre-existing statusline keeps working: the hook script delegates
        // to the command we save here after capturing the usage JSON.
        if let existing = (json["statusLine"] as? [String: Any])?["command"] as? String,
           !existing.contains("statusline-hook.sh") {
            try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
            try existing.write(
                to: supportDir.appendingPathComponent("original-statusline-command"),
                atomically: true, encoding: .utf8
            )
        }
        json["statusLine"] = ["type": "command", "command": statuslineCommand]

        var hooks = json["hooks"] as? [String: Any] ?? [:]
        for (event, arg) in lifecycleEvents where !registered(in: hooks, event: event) {
            var entries = hooks[event] as? [[String: Any]] ?? []
            entries.append(["hooks": [[
                "type": "command",
                "command": "bash \"$HOME/Library/Application Support/ClaudeBar/claudebar-hook.sh\" \(arg)",
            ]]])
            hooks[event] = entries
        }
        json["hooks"] = hooks

        let data = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try fm.createDirectory(
            at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: settingsURL, options: .atomic)
    }
}
