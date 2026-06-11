import AppKit
import Foundation
import UserNotifications

/// Posts macOS notifications for (a) sessions entering the waiting-for-input
/// state and (b) usage-window threshold crossings. All triggers are
/// edge-detected so repeated evaluate() calls never re-fire.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let defaultThresholds: [Double] = [75, 90]

    private enum Mode {
        case pending     // authorization not yet resolved
        case system      // UNUserNotificationCenter
        case osascript   // bundle/center unavailable — banner-only fallback
        case disabled    // user denied — respect it, post nothing
    }

    private var mode: Mode = .pending
    private var pendingPosts: [(title: String, body: String)] = []

    // Edge-detection state persists across relaunches — without this, every
    // restart re-fires thresholds and waiting alerts.
    private static let lastUtilizationKey = "notifyLastUtilization"
    private static let waitingIdsKey = "notifyWaitingSessionIds"

    private var lastUtilization: [String: Double] =
        UserDefaults.standard.dictionary(forKey: NotificationManager.lastUtilizationKey) as? [String: Double] ?? [:]
    private var notifiedWaitingIds: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: NotificationManager.waitingIdsKey) ?? [])

    func requestAuthorizationIfNeeded() async {
        guard case .pending = mode else { return }
        guard Bundle.main.bundleIdentifier != nil else {
            mode = .osascript
            Log.info("notifications: no bundle identifier, using osascript fallback")
            flushPendingPosts()
            return
        }
        do {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            mode = granted ? .system : .disabled
            Log.info("notifications: \(granted ? "authorized" : "denied by user — disabled")")
        } catch {
            mode = .osascript
            Log.error("notifications: auth error (\(error.localizedDescription)), using osascript fallback")
        }
        flushPendingPosts()
    }

    /// Triggers that fire before authorization resolves are queued, not lost.
    private func flushPendingPosts() {
        let queued = pendingPosts
        pendingPosts = []
        for item in queued {
            deliver(title: item.title, body: item.body)
        }
    }

    func evaluate(usage: UsageReport?, sessions: [Session]) {
        evaluateWaiting(sessions)
        evaluateThresholds(usage)
    }

    // MARK: - Waiting-for-input

    private func evaluateWaiting(_ sessions: [Session]) {
        var currentlyWaiting: Set<String> = []
        for session in sessions {
            guard case .waiting(let reason) = session.state else { continue }
            currentlyWaiting.insert(session.sessionId)
            if !notifiedWaitingIds.contains(session.sessionId) {
                post(
                    title: "Claude is waiting for you",
                    body: "\(session.title ?? session.display.project) (\(session.entrypoint.displayName)) — \(reason)"
                )
            }
        }
        // Leaving .waiting re-arms the session for its next prompt.
        if currentlyWaiting != notifiedWaitingIds {
            notifiedWaitingIds = currentlyWaiting
            UserDefaults.standard.set(Array(currentlyWaiting), forKey: Self.waitingIdsKey)
        }
    }

    // MARK: - Usage thresholds

    private func evaluateThresholds(_ usage: UsageReport?) {
        guard let usage else { return }
        check(usage.fiveHour, windowName: "5-hour")
        check(usage.sevenDay, windowName: "Weekly")
    }

    /// Fires only on an upward crossing: previous reading below the
    /// threshold, current at or above. A window reset drops utilization,
    /// which re-arms naturally. Immune to reset-timestamp jitter.
    private func check(_ window: UsageWindow?, windowName: String) {
        guard let window else { return }
        let isDebug = UserDefaults.standard.array(forKey: "debugThresholds") != nil
        let previous = isDebug ? 0 : (lastUtilization[windowName] ?? 0)
        defer {
            if lastUtilization[windowName] != window.utilization {
                lastUtilization[windowName] = window.utilization
                UserDefaults.standard.set(lastUtilization, forKey: Self.lastUtilizationKey)
            }
        }
        for threshold in activeThresholds()
        where previous < threshold && window.utilization >= threshold {
            let resets = window.resetsAt.map { " — resets in \(Formatters.countdown(to: $0))" } ?? ""
            post(
                title: "Claude usage at \(Int(window.utilization.rounded()))%",
                body: "\(windowName) window crossed \(Int(threshold))%\(resets)"
            )
        }
    }

    /// `defaults write dev.gogrow.claudebar debugThresholds -array 1` makes a
    /// notification fire at any nonzero usage, for manual testing.
    private func activeThresholds() -> [Double] {
        // `defaults write … -array 1` stores strings, `-array -int 1` stores
        // numbers — accept both.
        if let debug = UserDefaults.standard.array(forKey: "debugThresholds") {
            let values = debug.compactMap { item -> Double? in
                switch item {
                case let number as NSNumber: return number.doubleValue
                case let string as String: return Double(string)
                default: return nil
                }
            }
            if !values.isEmpty { return values }
        }
        return Self.defaultThresholds
    }

    // MARK: - Delivery

    private func post(title: String, body: String) {
        Log.info("notify: \(title) — \(body)")
        deliver(title: title, body: body)
    }

    private func deliver(title: String, body: String) {
        // Gear-menu kill switch; edge-detection state still advances above
        // so re-enabling doesn't replay stale alerts.
        guard UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true else {
            return
        }
        switch mode {
        case .pending:
            pendingPosts.append((title, body))
        case .disabled:
            return
        case .system:
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        case .osascript:
            let escapedTitle = escapeForAppleScript(title)
            let escapedBody = escapeForAppleScript(body)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "display notification \"\(escapedBody)\" with title \"\(escapedTitle)\""]
            try? process.run()
        }
    }

    private func escapeForAppleScript(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // Menu bar agent apps count as "foreground" — still show banners.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
