import Foundation

/// A one-shot HTTP listener on 127.0.0.1 that catches the OAuth redirect, so
/// signing in ends in the app instead of asking the user to copy a code out of a
/// web page. This is the approach RFC 8252 recommends for native apps, and what
/// `gh`, `gcloud` and `aws sso` do.
///
/// Anthropic's client accepts any loopback port (verified against the live
/// authorize endpoint), so the port is left to the kernel — nothing to configure
/// and nothing to collide with. A code intercepted by another local process is
/// useless without the PKCE verifier, which never leaves this process.
///
/// Deliberately a BSD socket rather than `NWListener`: the app ships without the
/// App Sandbox, so both are permitted, but this one can be exercised in a test
/// harness on any machine, and a sign-in path that can't be tested is a sign-in
/// path that breaks quietly.
///
/// The socket binds loopback only, serves until it has a usable callback, and is
/// closed on success, timeout, or cancellation.
/// `@unchecked Sendable`: the only mutable state is `closed`, guarded by `lock`.
final class LoopbackCallbackServer: @unchecked Sendable {
    struct Callback {
        let code: String
        let state: String
    }

    enum ListenError: Error { case cannotBind }

    private let listenFD: Int32
    private let queue = DispatchQueue(label: "com.nerlichman.claudebar.oauth-callback")
    private let lock = NSLock()
    private var closed = false

    /// The port the kernel handed us — the redirect URI has to name it.
    let port: UInt16

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ListenError.cannotBind }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0 // kernel picks
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            close(fd)
            throw ListenError.cannotBind
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else {
            close(fd)
            throw ListenError.cannotBind
        }

        self.listenFD = fd
        self.port = UInt16(bigEndian: assigned.sin_port)
    }

    /// Resolves with the first request carrying both `code` and `state`, or throws
    /// on timeout. Cancelling the surrounding task tears the socket down.
    func waitForCallback(timeout: TimeInterval = 300) async throws -> Callback {
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self.stop()
        }
        defer { timer.cancel(); stop() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do { continuation.resume(returning: try self.serveUntilCallback()) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: {
            stop()
        }
    }

    /// Closing the listening socket is what unblocks a parked `accept`.
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        close(listenFD)
    }

    private var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    /// Serves requests until one is a usable callback. Browsers ask for more than
    /// the redirect alone — Chrome fetches `/favicon.ico` against the same origin —
    /// so anything without both parameters is answered and skipped rather than
    /// mistaken for a failed sign-in.
    private func serveUntilCallback() throws -> Callback {
        while !isClosed {
            let connection = accept(listenFD, nil, nil)
            guard connection >= 0 else { throw ListenError.cannotBind }
            defer { close(connection) }

            let callback = Self.parse(requestHead: Self.readHead(connection))
            Self.respond(on: connection, success: callback != nil)
            if let callback { return callback }
        }
        throw CancellationError()
    }

    /// Reads to the end of the request head. Everything needed is in the request
    /// line, and the browser sends no body with a redirect GET.
    private static func readHead(_ fd: Int32) -> String {
        // Don't let a connection that opens and says nothing park us forever.
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var head = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while head.count < 32 * 1024 {
            let read = recv(fd, &buffer, buffer.count, 0)
            guard read > 0 else { break }
            head.append(contentsOf: buffer[0..<read])
            if let text = String(data: head, encoding: .utf8),
               text.contains("\r\n\r\n") || text.contains("\n\n") { break }
        }
        return String(decoding: head, as: UTF8.self)
    }

    private static func parse(requestHead: String) -> Callback? {
        guard let line = requestHead.split(whereSeparator: \.isNewline).first,
              let target = line.split(separator: " ").dropFirst().first,
              // A relative target needs a base before URLComponents will read it.
              let components = URLComponents(string: "http://127.0.0.1\(target)"),
              let items = components.queryItems
        else { return nil }
        let values = Dictionary(
            items.compactMap { item in item.value.map { (item.name, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        guard let code = values["code"], let state = values["state"],
              !code.isEmpty, !state.isEmpty
        else { return nil }
        return Callback(code: code, state: state)
    }

    private static func respond(on fd: Int32, success: Bool) {
        let body = Data(page(success: success).utf8)
        var head = "HTTP/1.1 \(success ? "200 OK" : "404 Not Found")\r\n"
        head += "Content-Type: text/html; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"

        let payload = Array(Data(head.utf8) + body)
        var sent = 0
        while sent < payload.count {
            let wrote = payload.withUnsafeBytes { raw in
                send(fd, raw.baseAddress!.advanced(by: sent), payload.count - sent, 0)
            }
            guard wrote > 0 else { break }
            sent += wrote
        }
    }

    /// The app icon, inlined because a page served over plain http can't fetch
    /// anything remote and shouldn't try. Read once; nil outside an app bundle,
    /// which is why `page(success:icon:)` still has a mark to fall back on.
    static let bundledIcon: Data? = Bundle.main
        .url(forResource: "AppIcon-128", withExtension: "png")
        .flatMap { try? Data(contentsOf: $0) }

    /// The page the browser lands on. Self-contained — no network requests from a
    /// page served over plain http — and readable in either system theme.
    /// Deliberately does not try `window.close()`: browsers refuse it for tabs a
    /// script didn't open, so it would fail silently and look broken.
    static func page(success: Bool, icon: Data? = bundledIcon) -> String {
        // The app icon carries the success case; a red cross reads as failure
        // faster than the icon plus a badge would.
        let mark: String
        if success, let icon {
            mark = #"<img class="icon" alt="" src="data:image/png;base64,\#(icon.base64EncodedString())">"#
        } else if success {
            mark = ##"<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 13l4 4L19 7" stroke="#2f9e63" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" fill="none"/></svg>"##
        } else {
            mark = ##"<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18" stroke="#c2544d" stroke-width="2.5" stroke-linecap="round" fill="none"/></svg>"##
        }
        let heading = success ? "Signed in to ClaudeBar" : "Sign-in didn’t complete"
        let detail = success
            ? "You can close this tab and go back to the menu bar."
            : "Something was missing from the callback. Try signing in again from ClaudeBar."
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(heading)</title>
        <style>
          :root { color-scheme: light dark; }
          body {
            margin: 0; min-height: 100vh;
            display: flex; align-items: center; justify-content: center;
            font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
            background: #f6f6f7; color: #1c1c1e;
          }
          .card { text-align: center; padding: 40px 32px; max-width: 22rem; }
          svg { width: 34px; height: 34px; margin-bottom: 14px; }
          .icon { width: 64px; height: 64px; margin-bottom: 14px; }
          h1 { font-size: 17px; font-weight: 600; margin: 0 0 6px; }
          p { margin: 0; color: #6b6b70; font-size: 13px; }
          @media (prefers-color-scheme: dark) {
            body { background: #1c1c1e; color: #f2f2f7; }
            p { color: #98989e; }
          }
        </style>
        </head>
        <body>
          <div class="card">
            \(mark)
            <h1>\(heading)</h1>
            <p>\(detail)</p>
          </div>
        </body>
        </html>
        """
    }
}
