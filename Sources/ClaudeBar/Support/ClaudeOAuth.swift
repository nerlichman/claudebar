import CryptoKit
import Foundation

/// The in-app "Sign in to Claude" flow: a standard OAuth 2.0 Authorization Code
/// grant with PKCE against the public Claude Code OAuth client. ClaudeBar opens
/// the authorize URL in the browser; after login the callback page shows a
/// `code#state` string the user copies back into the app, which this exchanges
/// for tokens and stores in ClaudeBar's own Keychain item.
///
/// This makes ClaudeBar self-sufficient: no terminal `/login`, no dependency on
/// the CLI's Keychain item. The resulting refresh token is what `ClaudeCredentials`
/// uses to mint fresh access tokens indefinitely.
enum ClaudeOAuth {
    // Subscription (Pro/Max "chat account") authorize — the `/cai/` path. NOT
    // platform.claude.com/oauth/authorize, which is the developer/API console
    // login and the wrong account type for subscription usage.
    private static let authorizeURL = "https://claude.com/cai/oauth/authorize"
    // Manual copy/paste flow: the callback page renders the code for the user.
    // Migrated to platform.claude.com alongside the token endpoint.
    private static let redirectURI = "https://platform.claude.com/oauth/code/callback"
    private static let scopes = "org:create_api_key user:profile user:inference"

    /// One in-flight login attempt. `verifier` and `state` must survive from
    /// building the URL until the code comes back — over the loopback listener if
    /// we got one, otherwise pasted by hand.
    struct PendingLogin {
        let verifier: String
        let state: String
        let url: URL
        /// Echoed back on the token exchange, so it has to match whichever
        /// redirect the authorize request actually asked for.
        let redirectURI: String
        let server: LoopbackCallbackServer?
    }

    /// Builds the authorize URL plus the PKCE secrets to hold onto. Prefers a
    /// loopback redirect so the browser hands the code straight back; falls back
    /// to the hosted page the user copies from if no port can be bound.
    static func begin() -> PendingLogin {
        let verifier = randomURLSafe(64)
        let challenge = codeChallenge(for: verifier)
        let state = randomURLSafe(32)

        let server = try? LoopbackCallbackServer()
        if server == nil {
            Log.error("oauth login: no loopback port — falling back to paste flow")
        }
        let redirect = server.map { "http://localhost:\($0.port)/callback" } ?? redirectURI

        var components = URLComponents(string: authorizeURL)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: ClaudeCredentials.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return PendingLogin(
            verifier: verifier, state: state, url: components.url!,
            redirectURI: redirect, server: server
        )
    }

    /// Waits for the browser to come back to the loopback listener, then finishes
    /// the exchange. Returns nil when there is no listener to wait on.
    static func completeViaLoopback(
        login: PendingLogin
    ) async -> Result<ClaudeCredentials.Credentials, ExchangeError>? {
        guard let server = login.server else { return nil }
        guard let callback = try? await server.waitForCallback() else { return nil }
        guard callback.state == login.state else { return .failure(.stateMismatch) }
        return await exchange(code: callback.code, state: callback.state, login: login)
    }

    enum ExchangeError: Error {
        case badCodeFormat
        case stateMismatch
        case exchangeFailed

        var userMessage: String {
            switch self {
            case .badCodeFormat: return "That doesn't look like a sign-in code"
            case .stateMismatch: return "Sign-in code didn't match this attempt — try again"
            case .exchangeFailed: return "Couldn't complete sign-in — try again"
            }
        }
    }

    /// Exchanges the pasted `code#state` for tokens and stores them. The pasted
    /// value may be the bare code or the full `code#state` the callback shows.
    static func complete(pasted: String, login: PendingLogin) async -> Result<ClaudeCredentials.Credentials, ExchangeError> {
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.badCodeFormat) }

        let parts = trimmed.split(separator: "#", maxSplits: 1).map(String.init)
        let code = parts[0]
        let state = parts.count > 1 ? parts[1] : login.state
        guard !code.isEmpty else { return .failure(.badCodeFormat) }
        guard state == login.state else { return .failure(.stateMismatch) }
        return await exchange(code: code, state: state, login: login)
    }

    /// Redeems an authorization code, however it arrived, and stores the result.
    private static func exchange(
        code: String, state: String, login: PendingLogin
    ) async -> Result<ClaudeCredentials.Credentials, ExchangeError> {
        let body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "client_id": ClaudeCredentials.clientID,
            "redirect_uri": login.redirectURI,
            "code_verifier": login.verifier,
        ]
        guard let token = await ClaudeCredentials.postToken(body),
              let refresh = token.refreshToken
        else { return .failure(.exchangeFailed) }

        let creds = ClaudeCredentials.store(
            accessToken: token.accessToken,
            refreshToken: refresh,
            expiresAt: token.expiresAt,
            scopes: token.scopes,
            service: ClaudeCredentials.ownService
        )
        Log.info("oauth login: stored ClaudeBar credentials")
        return .success(creds)
    }

    // MARK: - PKCE helpers

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    private static func randomURLSafe(_ byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
