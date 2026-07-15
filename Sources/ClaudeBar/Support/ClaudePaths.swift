import Foundation

/// Every path under ~/.claude that the app reads lives here.
/// The app NEVER writes to or deletes anything in these directories —
/// Claude Code owns them.
enum ClaudePaths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)

    /// One {pid}.json per live session, all surfaces (desktop, CLI, VS Code).
    static let sessionsDir = claudeDir.appendingPathComponent("sessions", isDirectory: true)

    /// Per-project transcript directories containing {sessionId}.jsonl files.
    static let projectsDir = claudeDir.appendingPathComponent("projects", isDirectory: true)

    /// One directory per background (daemon) job, each holding a state.json
    /// with the daemon's authoritative view of that agent — the same state
    /// Claude Code's FleetView renders.
    static let jobsDir = claudeDir.appendingPathComponent("jobs", isDirectory: true)

    static func jobStateFile(forJobId jobId: String) -> URL {
        jobsDir.appendingPathComponent(jobId, isDirectory: true)
            .appendingPathComponent("state.json", isDirectory: false)
    }

    /// Claude Code encodes a project cwd as a directory name by replacing
    /// every non-alphanumeric character with "-" (so "/" and "." both mangle).
    static func encodedProjectDir(for cwd: String) -> String {
        String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }
}
