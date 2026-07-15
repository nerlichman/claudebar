import Foundation

/// Reads the daemon's authoritative state for a background agent from
/// ~/.claude/jobs/{jobId}/state.json — the same source Claude Code's FleetView
/// renders. This beats guessing from the transcript window or lifecycle hooks:
/// a bg agent's session file only carries busy/idle, and a "needs input" block
/// is invisible there, but the job state names it outright (`tempo` + `needs`).
final class JobStateReader {
    struct JobState {
        /// Live activity: "active" (working), "blocked" (needs input),
        /// "idle" (finished/waiting to be told what's next).
        let tempo: String?
        /// Lifecycle: "done" once the agent has wrapped up, else "blocked" etc.
        let state: String?
        /// When blocked, the human-readable thing the agent is waiting on.
        let needs: String?
    }

    private struct Payload: Decodable {
        let tempo: String?
        let state: String?
        let needs: String?
        let detail: String?
    }

    private let fm = FileManager.default
    private var cache: [String: (value: JobState?, mtime: Date)] = [:]

    func state(forJobId jobId: String?) -> JobState? {
        guard let jobId, !jobId.isEmpty else { return nil }
        let url = ClaudePaths.jobStateFile(forJobId: jobId)

        // The daemon rewrites state.json frequently; key the cache on mtime so
        // a fresh write invalidates it but repeated reads within a tick don't
        // re-parse.
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        if let cached = cache[jobId], cached.mtime == mtime { return cached.value }

        let value: JobState?
        if let data = try? Data(contentsOf: url),
           let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            value = JobState(
                tempo: payload.tempo,
                state: payload.state,
                needs: (payload.needs ?? payload.detail).flatMap { $0.isEmpty ? nil : $0 }
            )
        } else {
            value = nil
        }
        cache[jobId] = (value, mtime)
        return value
    }
}
