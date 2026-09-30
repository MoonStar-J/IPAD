import AuthenticationServices
import Network
import UIKit

/// The HTTP callback is received by Network.framework, not by pretending that
/// http is a custom ASWebAuthenticationSession callback scheme.
@MainActor final class ChatGPTSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var browser: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<(OAuthAttempt, String, String), Error>?
    private var ready: CheckedContinuation<UInt16, Error>?
    private var timeout: Task<Void, Never>?
    private var attempt: OAuthAttempt?
    private var anchor: UIWindow?
    private var ended = false
    #if DEBUG
    // Used only by the isolated simulator fixture; never exchanges credentials.
    var localCallbackProbe = false
    #endif

    func run(hostID: String, profile: PlanRegistration?, requestConsent: Bool = false) async throws -> (OAuthAttempt, String, String) {
        defer { if !ended { finish(.failure(CancellationError())) } }
        try Task.checkCancellation()
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).filter({ $0.activationState == .foregroundActive }).flatMap(\.windows).first(where: \.isKeyWindow) else { throw PlanFailure(kind: .authentication, code: "presentation_not_ready") }
        anchor = window
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let local = try NWListener(using: parameters)
        listener = local
        local.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.accept(connection) } }
        local.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    if let port = self.listener?.port { self.ready?.resume(returning: port.rawValue); self.ready = nil }
                case .failed: self.finish(.failure(PlanFailure(kind: .network, code: "loopback_unavailable")))
                default: break
                }
            }
        }
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(180)) } catch { return }
            self?.finish(.failure(PlanFailure(kind: .network, code: "sign_in_timeout")))
        }
        return try await withTaskCancellationHandler {
            let port: UInt16 = try await withCheckedThrowingContinuation { pending in
                if ended || Task.isCancelled { pending.resume(throwing: CancellationError()) }
                else { ready = pending; local.start(queue: .main) }
            }
            try Task.checkCancellation()
            let pending = try OAuthAttempt(redirect: URL(string: "http://127.0.0.1:\(port)/auth/callback")!, registeredClient: profile?.id)
            attempt = pending
            return try await withCheckedThrowingContinuation { callback in
                continuation = callback
                // nil is intentional: the documented HTTP loopback goes to our
                // bound listener. The session remains the supported system UI.
                var authorizationURL = pending.authorization(hostID: hostID, idTokenHint: profile?.tokens?.id_token, requestConsent: requestConsent)
                #if DEBUG
                if localCallbackProbe { authorizationURL = URL(string: "http://127.0.0.1:\(port)/local-probe")! }
                #endif
                let session = ASWebAuthenticationSession(url: authorizationURL, callbackURLScheme: nil) { [weak self] _, _ in
                    Task { @MainActor in self?.finish(.failure(CancellationError())) }
                }
                session.presentationContextProvider = self
                browser = session
                if !session.start() { finish(.failure(PlanFailure(kind: .authentication, code: "system_session_unavailable"))) }
            }
        } onCancel: { Task { @MainActor in self.cancel() } }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor ?? UIWindow() }
    func cancel() { finish(.failure(CancellationError())) }
    private func accept(_ connection: NWConnection) {
        guard !ended, connections.count < 8 else { connection.cancel(); return }
        connections.append(connection)
        connection.start(queue: .main)
        read(connection, buffer: Data())
    }
    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] bytes, _, done, error in
            Task { @MainActor in
                guard let self, !self.ended else { connection.cancel(); return }
                var data = buffer; if let bytes { data.append(bytes) }
                guard data.count < 32_768 else { self.reply(connection, ok: false); return }
                if let request = String(data: data, encoding: .utf8), request.contains("\r\n\r\n") {
                    let first = request.components(separatedBy: "\r\n")[0].split(separator: " ")
                    #if DEBUG
                    if self.localCallbackProbe, first.count == 3, first[0] == "GET", first[1] == "/local-probe", let attempt = self.attempt {
                        let location = attempt.redirect.absoluteString + "?state=\(attempt.state)&code=local-probe-no-token&client_id=oaiapp_local_probe"
                        let redirect = "HTTP/1.1 302 Found\r\nLocation: \(location)\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
                        connection.send(content: Data(redirect.utf8), completion: .contentProcessed { _ in connection.cancel() })
                        self.connections.removeAll { $0 === connection }; return
                    }
                    #endif
                    guard first.count == 3, first[0] == "GET", let attempt = self.attempt,
                          first[1].hasPrefix("/auth/callback?"),
                          let url = URL(string: "http://127.0.0.1:\(attempt.redirect.port!)" + first[1]) else { self.reply(connection, ok: false); return }
                    do {
                        let result = try attempt.callback(url)
                        self.reply(connection, ok: true)
                        self.finish(.success((attempt, result.code, result.client)), completedConnection: connection)
                    } catch let failure as PlanFailure where failure.code == "consent_denied" {
                        self.reply(connection, ok: false); self.finish(.failure(failure), completedConnection: connection)
                    } catch { self.reply(connection, ok: false) }
                } else if done || error != nil { connection.cancel(); self.connections.removeAll { $0 === connection } }
                else { self.read(connection, buffer: data) }
            }
        }
    }
    private func reply(_ connection: NWConnection, ok: Bool) {
        let body = ok ? "Sign-in received. Return to note margin." : "Invalid callback. Return to note margin."
        let response = "HTTP/1.1 \(ok ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        connections.removeAll { $0 === connection }
    }
    private func finish(_ result: Result<(OAuthAttempt, String, String), Error>, completedConnection: NWConnection? = nil) {
        guard !ended else { return }; ended = true
        timeout?.cancel(); timeout = nil
        listener?.cancel(); listener = nil
        for connection in connections where connection !== completedConnection { connection.cancel() }; connections = []
        browser?.cancel(); browser = nil; anchor = nil
        if let ready { self.ready = nil; ready.resume(throwing: CancellationError()) }
        continuation?.resume(with: result); continuation = nil
    }
}
