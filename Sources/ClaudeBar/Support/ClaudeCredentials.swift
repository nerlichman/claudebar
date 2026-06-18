import Foundation

/// Reads, refreshes, and stores Claude OAuth credentials in the login Keychain.
///
/// ClaudeBar keeps its **own** credential item (`ClaudeBar-credentials`), seeded
/// by the in-app "Sign in to Claude" flow (`ClaudeOAuth`). That makes it fully
/// independent of the terminal: once you sign in, the stored refresh token lets
/// ClaudeBar mint fresh access tokens forever, with no CLI session required.
///
/// For backwards compatibility it still falls back to reading the Claude Code
/// *CLI* item (`Claude Code-credentials`) when ClaudeBar has no item of its own
/// — but that one is only refreshed while the CLI runs, which is exactly why
/// desktop-only use let the token go stale. After an in-app sign-in, ClaudeBar's
/// own item takes over and the staleness is gone.
///
/// Reads/writes shell out to /usr/bin/security — mirroring the user's working
/// command and sidestepping SecItem code-signing identity mismatches. The first
/// access triggers the standard Keychain prompt; once the user clicks "Always
/// Allow", later access is silent. These calls may block on that GUI prompt, so
/// they must never run on the main thread — `ClaudeTokenProvider` is an actor,
/// which keeps them off it.
enum ClaudeCredentials {
    /// ClaudeBar's own item, written by the in-app OAuth login.
    static let ownService = "ClaudeBar-credentials"
    /// The Claude Code CLI's item, read-only fallback for existing users.
    static let cliService = "Claude Code-credentials"

    // Public OAuth client id used by the Claude Code CLI.
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let tokenEndpoint = URL(string: "https://console.anthropic.com/v1/oauth/token")!

    /// Parsed snapshot of a Keychain item plus the full JSON root, kept so a
    /// refresh can rewrite only the OAuth fields and preserve everything else
    /// (scopes, subscriptionType, rateLimitTier, …). `service` records which
    /// item it came from so a refresh writes back to the same place.
    struct Credentials {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var root: [String: Any]
        var service: String
    }

    /// Raw access token as currently stored, with no refresh.
    static func accessToken() -> String? { read()?.accessToken }

    // MARK: - Keychain read

    /// ClaudeBar's own item wins; the CLI item is the fallback.
    static func read() -> Credentials? {
        read(from: ownService) ?? read(from: cliService)
    }

    static func read(from service: String) -> Credentials? {
        guard let json = runSecurity(["find-generic-password", "-s", service, "-w"]),
              let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty
        else { return nil }

        var expiresAt: Date?
        switch oauth["expiresAt"] {
        case let ms as Double: expiresAt = Date(timeIntervalSince1970: ms / 1000)
        case let ms as Int: expiresAt = Date(timeIntervalSince1970: Double(ms) / 1000)
        default: break
        }

        return Credentials(
            accessToken: token,
            refreshToken: oauth["refreshToken"] as? String,
            expiresAt: expiresAt,
            root: root,
            service: service
        )
    }

    // MARK: - Token build / store

    /// Wraps token fields in the `claudeAiOauth` JSON shape, persists them to
    /// ClaudeBar's own item, and returns the stored credential. Used by both the
    /// OAuth login and refresh.
    @discardableResult
    static func store(
        accessToken: String,
        refreshToken: String,
        expiresAt: Date?,
        scopes: [String]? = nil,
        merging base: Credentials? = nil,
        service: String? = nil
    ) -> Credentials {
        var oauth = (base?.root["claudeAiOauth"] as? [String: Any]) ?? [:]
        oauth["accessToken"] = accessToken
        oauth["refreshToken"] = refreshToken
        if let expiresAt { oauth["expiresAt"] = expiresAt.timeIntervalSince1970 * 1000 }
        if let scopes { oauth["scopes"] = scopes }
        var root = base?.root ?? [:]
        root["claudeAiOauth"] = oauth

        let target = service ?? base?.service ?? ownService
        let creds = Credentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            root: root,
            service: target
        )
        writeBack(creds)
        return creds
    }

    // MARK: - OAuth refresh

    /// Exchanges the refresh token for a fresh access token, returning updated
    /// credentials with the rotated tokens merged into `base.root` and written
    /// back to the same Keychain item. Returns nil on any failure — callers fall
    /// back to the existing token.
    static func refresh(refreshToken: String, base: Credentials) async -> Credentials? {
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        guard let token = await postToken(body) else { return nil }
        let creds = store(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken ?? refreshToken,
            expiresAt: token.expiresAt,
            scopes: token.scopes,
            merging: base,
            service: base.service
        )
        Log.info("token refresh: ok (expires \(token.expiresAt.map { "in \(Int($0.timeIntervalSinceNow / 60))m" } ?? "n/a"))")
        return creds
    }

    /// Shared POST to the token endpoint for both authorization-code exchange
    /// and refresh. Parses the standard OAuth token response.
    struct TokenResponse {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var scopes: [String]?
    }

    static func postToken(_ body: [String: String]) async -> TokenResponse? {
        var request = URLRequest(url: tokenEndpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            Log.error("oauth token: network error (\(error.localizedDescription))")
            return nil
        }
        guard let http = response as? HTTPURLResponse else { return nil }
        guard (200..<300).contains(http.statusCode) else {
            Log.error("oauth token: HTTP \(http.statusCode)")
            return nil
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty
        else {
            Log.error("oauth token: response not understood")
            return nil
        }
        let expiresIn = (json["expires_in"] as? Double) ?? (json["expires_in"] as? Int).map(Double.init)
        let scopes = (json["scope"] as? String)?.split(separator: " ").map(String.init)
        return TokenResponse(
            accessToken: access,
            refreshToken: json["refresh_token"] as? String,
            expiresAt: expiresIn.map { Date().addingTimeInterval($0) },
            scopes: scopes
        )
    }

    // MARK: - Keychain write

    /// Persists credentials to their item. Best-effort: a failure is non-fatal
    /// because the caller keeps using the in-memory token for the session.
    private static func writeBack(_ creds: Credentials) {
        guard let data = try? JSONSerialization.data(withJSONObject: creds.root),
              let json = String(data: data, encoding: .utf8)
        else { return }
        let account = keychainAccount(for: creds.service)
        // -U updates the existing item in place (matched on service+account)
        // rather than erroring on a duplicate.
        let ok = runSecurity([
            "add-generic-password", "-U",
            "-s", creds.service, "-a", account, "-w", json,
        ]) != nil
        if !ok { Log.error("oauth: keychain write to \(creds.service) failed (using in-memory token)") }
    }

    /// The account an existing item is stored under (so an update matches it),
    /// falling back to the login name for a brand-new item.
    private static func keychainAccount(for service: String) -> String {
        guard let attrs = runSecurity(["find-generic-password", "-s", service]),
              let range = attrs.range(of: #""acct"<blob>=""#)
        else { return NSUserName() }
        let rest = attrs[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return NSUserName() }
        let acct = String(rest[..<end])
        return acct.isEmpty ? NSUserName() : acct
    }

    // MARK: - security(1) shell-out

    /// Runs /usr/bin/security and returns trimmed stdout+stderr, or nil on a
    /// non-zero exit / launch failure. `add-generic-password` prints nothing on
    /// success, so an empty zero-exit run returns "" (success to callers).
    @discardableResult
    private static func runSecurity(_ arguments: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = arguments
        let out = Pipe()
        // `find-generic-password` (no -w) prints attributes to stderr.
        let err = Pipe()
        task.standardOutput = out
        task.standardError = err
        do {
            try task.run()
        } catch {
            Log.error("keychain: failed to launch security (\(error.localizedDescription))")
            return nil
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let combined = (String(data: outData, encoding: .utf8) ?? "")
            + (String(data: errData, encoding: .utf8) ?? "")
        return combined.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Serializes credential reads and refreshes behind an actor, and caches the
/// freshest credential seen so a write-back failure (or another writer) never
/// sends us back to a stale token.
actor ClaudeTokenProvider {
    static let shared = ClaudeTokenProvider()

    /// Refresh once the token is within this window of expiry.
    private static let refreshSkew: TimeInterval = 5 * 60

    private var cached: ClaudeCredentials.Credentials?

    /// Adopt credentials just minted by the in-app login so the next poll uses
    /// them without waiting on a Keychain round-trip.
    func adopt(_ creds: ClaudeCredentials.Credentials) { cached = creds }

    /// A currently-valid access token, refreshing via the stored refresh token
    /// when the freshest known credential is expired or nearly so. Returns nil
    /// only when there's no readable item at all. Pass `forceRefresh` after a
    /// 401 to refresh even if the clock says valid.
    func validToken(forceRefresh: Bool = false) async -> String? {
        let disk = ClaudeCredentials.read()
        // Trust whichever of {cached, on-disk} expires later: covers both a
        // failed write-back (cached newer) and another writer (disk newer).
        let best = [cached, disk]
            .compactMap { $0 }
            .max { ($0.expiresAt ?? .distantPast) < ($1.expiresAt ?? .distantPast) }
        guard let creds = best else { return nil }

        let secondsLeft = creds.expiresAt?.timeIntervalSinceNow ?? -1
        if !forceRefresh, secondsLeft > Self.refreshSkew {
            cached = creds
            return creds.accessToken
        }
        guard let refreshToken = creds.refreshToken else {
            cached = creds
            return creds.accessToken
        }
        if let refreshed = await ClaudeCredentials.refresh(refreshToken: refreshToken, base: creds) {
            cached = refreshed
            return refreshed.accessToken
        }
        cached = creds
        return creds.accessToken
    }
}
