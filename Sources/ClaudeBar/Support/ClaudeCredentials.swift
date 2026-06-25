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
    // Anthropic migrated OAuth to platform.claude.com; the old
    // console.anthropic.com host is deprecated (gone from Claude Code's client).
    static let tokenEndpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!

    // Token endpoint ONLY. platform.claude.com is behind Cloudflare bot
    // management, which 429s the `claude-code/*` UA at the edge — so send a
    // generic app UA here. (The usage endpoint is the opposite and wants the
    // claude-code UA; see OAuthUsageFetcher.)
    static let tokenUserAgent: String = {
        let v = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
        return "ClaudeBar/\(v)"
    }()

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

    // MARK: - Token endpoint backoff

    /// After a 429 we stop refreshing for a while: each attempt resets the
    /// server's penalty window, so polling through a rate limit keeps it alive.
    /// Persisted so a relaunch can't immediately re-hammer.
    private static let tokenCooldownKey = "tokenEndpointCooldownUntil"
    private static let tokenCooldownCountKey = "tokenEndpointCooldownCount"
    // Escalating: after repeated failures we probe at most ~daily, so a dead
    // token can't self-poke the endpoint for hours. A single success resets it.
    private static let tokenCooldownSteps: [TimeInterval] = [30 * 60, 2 * 3600, 6 * 3600, 24 * 3600]

    static func isTokenEndpointCoolingDown() -> Bool {
        Date().timeIntervalSince1970 < UserDefaults.standard.double(forKey: tokenCooldownKey)
    }

    static func tokenCooldownRemaining() -> TimeInterval {
        max(0, UserDefaults.standard.double(forKey: tokenCooldownKey) - Date().timeIntervalSince1970)
    }

    private static func noteTokenEndpointRateLimited(escalate: Bool = true) {
        let n: Int
        if escalate {
            n = UserDefaults.standard.integer(forKey: tokenCooldownCountKey) + 1
            UserDefaults.standard.set(n, forKey: tokenCooldownCountKey)
        } else {
            // A user sign-in must neither ratchet the ramp nor inherit a prior
            // escalated count (one 429 could otherwise arm 24h) — gentlest step.
            n = 1
        }
        let cooldown = tokenCooldownSteps[min(n, tokenCooldownSteps.count) - 1]
        // Never shorten an already-armed (escalated) window.
        let until = Date().timeIntervalSince1970 + cooldown
        let existing = UserDefaults.standard.double(forKey: tokenCooldownKey)
        UserDefaults.standard.set(max(existing, until), forKey: tokenCooldownKey)
        Log.error("oauth token: rate-limited (x\(n)\(escalate ? "" : ", manual")), backing off refreshes for \(Int(cooldown / 60))m")
    }

    private static func clearTokenEndpointCooldown() {
        UserDefaults.standard.removeObject(forKey: tokenCooldownKey)
        UserDefaults.standard.removeObject(forKey: tokenCooldownCountKey)
    }

    // MARK: - OAuth refresh

    /// Default subscription scopes, sent on refresh exactly as Claude Code does.
    /// Used when the stored credential doesn't record its own scope list.
    static let defaultScopes = "org:create_api_key user:profile user:inference"

    /// Exchanges the refresh token for a fresh access token, returning updated
    /// credentials with the rotated tokens merged into `base.root` and written
    /// back to the same Keychain item. Returns nil on any failure — callers fall
    /// back to the existing token.
    static func refresh(refreshToken: String, base: Credentials) async -> Credentials? {
        // Send the granted scopes (mirrors Claude Code's refresh body).
        let storedScopes = (base.root["claudeAiOauth"] as? [String: Any])?["scopes"] as? [String]
        let scope = (storedScopes?.isEmpty == false ? storedScopes!.joined(separator: " ") : defaultScopes)
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
            "scope": scope,
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
        // JSON body — what Claude Code's own client sends (verified against the
        // CLI binary). The endpoint rejects a form-encoded body (a different path).
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        // Must NOT be the claude-code UA — Cloudflare blocks it here. See tokenUserAgent.
        request.setValue(tokenUserAgent, forHTTPHeaderField: "User-Agent")
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
            // Log the OAuth error code (invalid_grant vs invalid_request) — tells
            // us if the token is dead or the request is wrong. No secret in it.
            let errorBody = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Log.error("oauth token: HTTP \(http.statusCode) \(errorBody.prefix(300))")
            // Only the background refresh arms/escalates the backoff; a user
            // sign-in (authorization_code) getting throttled shouldn't.
            if http.statusCode == 429 {
                noteTokenEndpointRateLimited(escalate: body["grant_type"] == "refresh_token")
            }
            return nil
        }
        clearTokenEndpointCooldown()
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

    /// Persists credentials to their item. The rotated refresh token MUST land
    /// here — the server already invalidated the previous one, so a lost write
    /// leaves a dead credential on next launch. Hence the retry-once on failure.
    private static func writeBack(_ creds: Credentials) {
        guard let data = try? JSONSerialization.data(withJSONObject: creds.root),
              let json = String(data: data, encoding: .utf8)
        else {
            Log.error("oauth: could not serialize credentials for \(creds.service) (keeping in-memory token)")
            return
        }
        let account = keychainAccount(for: creds.service)
        // -U updates the existing item in place (matched on service+account)
        // rather than erroring on a duplicate.
        func attempt() -> Bool {
            runSecurity([
                "add-generic-password", "-U",
                "-s", creds.service, "-a", account, "-w", json,
            ]) != nil
        }
        if attempt() { return }
        Log.error("oauth: keychain write to \(creds.service) failed, retrying once")
        if attempt() { return }
        Log.error("oauth: keychain write to \(creds.service) failed twice — rotated refresh token persisted only in memory; a relaunch before the next successful write may require re-sign-in")
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
        // Fast path: a still-valid cached token needs no Keychain I/O.
        if !forceRefresh, let c = cached, Self.isFresh(c) {
            return c.accessToken
        }

        // We may READ the CLI item and use its token, but must never REFRESH it:
        // rotating the CLI's token would invalidate it under the running CLI.
        // Only our own item is ours to renew.
        let candidates = [
            cached,
            ClaudeCredentials.read(from: ClaudeCredentials.ownService),
            ClaudeCredentials.read(from: ClaudeCredentials.cliService),
        ].compactMap { $0 }
        guard !candidates.isEmpty else { return nil }

        // Freshest still-valid credential (read-only, so the CLI token counts).
        let freshestValid = candidates.filter { Self.isFresh($0) }.max(by: Self.byExpiry)
        if !forceRefresh, let valid = freshestValid {
            cached = valid
            return valid.accessToken
        }

        // Refresh our OWN item only, and not during a 429 cooldown.
        if !ClaudeCredentials.isTokenEndpointCoolingDown(),
           let own = candidates
               .filter({ $0.service == ClaudeCredentials.ownService })
               .max(by: Self.byExpiry),
           let refreshToken = own.refreshToken,
           let refreshed = await ClaudeCredentials.refresh(refreshToken: refreshToken, base: own) {
            cached = refreshed
            return refreshed.accessToken
        }

        // Couldn't renew — fall back to any still-valid token (e.g. the CLI's).
        if let valid = freshestValid {
            cached = valid
            return valid.accessToken
        }
        // Last resort: the newest stale token; the caller handles the likely 401.
        let newest = candidates.max(by: Self.byExpiry)
        if let newest { cached = newest }
        return newest?.accessToken
    }

    private static func isFresh(_ creds: ClaudeCredentials.Credentials) -> Bool {
        (creds.expiresAt?.timeIntervalSinceNow ?? -1) > refreshSkew
    }

    /// Orders credentials by expiry so `.max(by:)` picks the latest-expiring one.
    private static func byExpiry(_ a: ClaudeCredentials.Credentials, _ b: ClaudeCredentials.Credentials) -> Bool {
        (a.expiresAt ?? .distantPast) < (b.expiresAt ?? .distantPast)
    }
}
