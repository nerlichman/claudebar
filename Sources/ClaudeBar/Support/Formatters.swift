import Foundation

enum Formatters {
    /// "konvoy-api · worktree reverent-noether" style display for a session cwd.
    static func projectDisplay(cwd: String) -> ProjectDisplay {
        let marker = "/.claude/worktrees/"
        if let range = cwd.range(of: marker) {
            let projectPath = String(cwd[..<range.lowerBound])
            let project = (projectPath as NSString).lastPathComponent
            var worktree = String(cwd[range.upperBound...])
            if let slash = worktree.firstIndex(of: "/") {
                worktree = String(worktree[..<slash])
            }
            return ProjectDisplay(
                project: project.isEmpty ? cwd : project,
                detail: "worktree \(strippingHashSuffix(worktree))"
            )
        }
        let home = ClaudePaths.home.path
        if cwd == home { return ProjectDisplay(project: "~", detail: nil) }
        let name = (cwd as NSString).lastPathComponent
        return ProjectDisplay(project: name.isEmpty ? cwd : name, detail: nil)
    }

    /// Drops a trailing "-a52a0f"-style hex suffix from worktree names.
    static func strippingHashSuffix(_ name: String) -> String {
        guard let dash = name.lastIndex(of: "-") else { return name }
        let suffix = name[name.index(after: dash)...]
        let isHex = suffix.count == 6 && suffix.allSatisfy { $0.isHexDigit && !$0.isUppercase }
        return isHex ? String(name[..<dash]) : name
    }

    /// "2h 14m" / "14m" / "<1m" countdown text.
    static func countdown(to date: Date, from now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "now" }
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }

    /// "now" / "3m" / "2h" / "5d" — compact age for badges.
    static func ageShort(from date: Date, to now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    /// "just now" / "3m ago" / "2h ago" relative age text.
    static func ago(from date: Date, to now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    /// "1.2M" / "45.3k" / "812" token count.
    static func tokenCount(_ count: Int) -> String {
        switch count {
        case ..<1_000: return "\(count)"
        case ..<1_000_000: return String(format: "%.1fk", Double(count) / 1_000)
        default: return String(format: "%.1fM", Double(count) / 1_000_000)
        }
    }

    /// Best-effort current git branch for a cwd. Handles both .git
    /// directories and .git files (worktrees). Returns nil on any failure.
    static func gitBranch(cwd: String) -> String? {
        let fm = FileManager.default
        let dotGit = (cwd as NSString).appendingPathComponent(".git")

        var gitDir = dotGit
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: dotGit, isDirectory: &isDirectory) else { return nil }
        if !isDirectory.boolValue {
            guard let contents = try? String(contentsOfFile: dotGit, encoding: .utf8),
                  let line = contents.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") })
            else { return nil }
            gitDir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            if !gitDir.hasPrefix("/") {
                gitDir = (cwd as NSString).appendingPathComponent(gitDir)
            }
        }

        let headPath = (gitDir as NSString).appendingPathComponent("HEAD")
        guard let head = try? String(contentsOfFile: headPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        if head.hasPrefix("ref: refs/heads/") {
            return String(head.dropFirst("ref: refs/heads/".count))
        }
        return head.count >= 7 ? String(head.prefix(7)) : nil
    }
}
