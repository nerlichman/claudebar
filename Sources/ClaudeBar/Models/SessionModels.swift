import Foundation

enum Entrypoint: Equatable {
    case cli
    case claudeDesktop
    case claudeVscode
    case unknown(String)

    init(rawValue: String?) {
        switch rawValue {
        case "cli": self = .cli
        case "claude-desktop": self = .claudeDesktop
        case "claude-vscode": self = .claudeVscode
        default: self = .unknown(rawValue ?? "?")
        }
    }

    var symbolName: String {
        switch self {
        case .cli: return "apple.terminal"
        case .claudeDesktop: return "macwindow.and.cursorarrow"
        case .claudeVscode: return "curlybraces.square"
        case .unknown: return "questionmark.app"
        }
    }

    var displayName: String {
        switch self {
        case .cli: return "Terminal"
        case .claudeDesktop: return "Desktop"
        case .claudeVscode: return "VS Code"
        case .unknown(let raw): return raw
        }
    }
}

/// Mirrors ~/.claude/sessions/{pid}.json. Unknown fields are ignored;
/// every field beyond pid/sessionId/cwd/startedAt is optional so schema
/// drift degrades gracefully.
struct SessionFile: Decodable {
    let pid: Int32
    let sessionId: String
    let cwd: String
    let startedAt: Double // ms epoch
    let procStart: String?
    let version: String?
    let kind: String?
    let name: String?       // FleetView's session label, e.g. "stripe connect integration"
    let jobId: String?      // daemon job id; keys ~/.claude/jobs/{jobId}/state.json
    let entrypoint: String?
    let status: String?     // "waiting" when blocked on user input
    let waitingFor: String? // e.g. "permission prompt"
    let updatedAt: Double?  // ms epoch
}

enum ActivityState: Equatable {
    case active
    case waiting(reason: String)
    case idle
    /// No live process — reconstructed from today's transcript.
    case ended

    var sortRank: Int {
        switch self {
        case .waiting: return 0
        case .active: return 1
        case .idle: return 2
        case .ended: return 3
        }
    }

    var logToken: String {
        switch self {
        case .active: return "active"
        case .waiting: return "waiting"
        case .idle: return "idle"
        case .ended: return "ended"
        }
    }
}

struct ProjectDisplay: Equatable {
    let project: String
    let detail: String? // e.g. "worktree reverent-noether"
}

struct Session: Identifiable, Equatable {
    var id: String { sessionId }

    let pid: Int32
    let sessionId: String
    let cwd: String
    let startedAt: Date
    let entrypoint: Entrypoint
    /// Human-readable session title (desktop metadata or transcript slug).
    var title: String?
    /// The desktop app's `local_…` session id, when it knows this session —
    /// enables deep-linking to the exact session view on click.
    var desktopSessionId: String?
    var state: ActivityState
    var lastTranscriptActivity: Date?
    /// Best-known moment of real engagement: hook event, transcript write,
    /// or session-file update — whichever is latest.
    var lastInteraction: Date?
    /// Idle with no engagement for a while — a live process that isn't part
    /// of the user's current working set (e.g. VS Code background instances).
    var isDormant: Bool
    var gitBranch: String?
    var display: ProjectDisplay
}
