import Foundation

final class MemoryPlanVault: PlanVault {
    var value = PlanVaultState()
    func read() throws -> PlanVaultState { value }
    func write(_ state: PlanVaultState) throws { value = state }
}
final class PlanMockProtocol: URLProtocol, @unchecked Sendable {
    static var count = 0
    static var forms: [String] = []
    static var status = 200
    static var data = Data()
    static var contentType = "application/json"
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.count += 1
        if let stream = request.httpBodyStream {
            stream.open(); var buffer = [UInt8](repeating: 0, count: 8192); var collected = Data()
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; collected.append(contentsOf: buffer.prefix(count)) }; stream.close()
            Self.forms.append(String(decoding: collected, as: UTF8.self))
        } else { Self.forms.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self)) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: ["Content-Type":Self.contentType])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct PlanSessionChecks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw NSError(domain: name, code: 1) }; count += 1; print("PASS " + name)
        }
        let vault = MemoryPlanVault()
        let old = PlanTokens(access_token: "old-fixture", refresh_token: "old-refresh", token_type: "Bearer", expires_in: 1, scope: "chatgpt.tokens.use.direct")
        vault.value.registrations = [.init(id: "client-a", identity: .init(subject: "a", email: "same@example.test"), tokens: old, receivedAt: Date(timeIntervalSinceNow: -100)), .init(id: "client-b", identity: .init(subject: "b", email: "same@example.test"), tokens: old, receivedAt: Date())]
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PlanMockProtocol.self]
        let transport = PlanHTTP(session: URLSession(configuration: config))
        let session = PlanCredentialSession(vault: vault, http: transport)
        PlanMockProtocol.data = Data(#"{"access_token":"new-fixture","refresh_token":"new-refresh","token_type":"Bearer","expires_in":3600,"scope":"chatgpt.tokens.use.direct"}"#.utf8)
        async let a = session.credentials(client: "client-a")
        async let b = session.credentials(client: "client-a")
        let pair = try await (a, b)
        try check(PlanMockProtocol.count == 1, "single-flight refresh sends exactly one request")
        try check(pair.0.access_token == "new-fixture" && pair.1.refresh_token == "new-refresh", "waiters receive the rotated credentials")
        try check(vault.value.registrations[0].tokens?.refresh_token == "new-refresh" && vault.value.registrations[0].pendingRotation == nil, "atomic rotation replaces complete record")
        try check(vault.value.registrations[1].tokens?.access_token == "old-fixture", "same email registrations remain isolated")
        try check(PlanMockProtocol.forms[0].contains("client_id=client-a") && !PlanMockProtocol.forms[0].contains("scope="), "refresh uses issued client and retained grant")
        vault.value.registrations[0].tokens?.scope = "openid email"
        do { _ = try await session.credentials(client: "client-a"); throw NSError(domain: "scope must block", code: 1) }
        catch let error as PlanFailure { try check(error.kind == .permission && PlanMockProtocol.count == 1, "missing plan scope blocks network") }
        vault.value.registrations[0].tokens = old
        PlanMockProtocol.status = 400; PlanMockProtocol.data = Data(#"{"error":"invalid_grant"}"#.utf8)
        do { _ = try await session.credentials(client: "client-a"); throw NSError(domain: "invalid grant must fail", code: 1) }
        catch let error as PlanFailure { try check(error.code == "invalid_grant" && vault.value.registrations[0].tokens == nil, "terminal refresh failure clears unusable tokens") }
        vault.value.registrations[0].tokens = old
        PlanMockProtocol.status = 503; PlanMockProtocol.data = Data("temporary outage".utf8)
        do { _ = try await session.credentials(client: "client-a"); throw NSError(domain: "network must fail", code: 1) }
        catch { try check(vault.value.registrations[0].tokens?.refresh_token == "old-refresh", "temporary failure retains credentials without automatic retry") }
        // Exercise the actual HTTP/SSE transport against a URLProtocol, never the network.
        PlanMockProtocol.status = 200; PlanMockProtocol.contentType = "text/event-stream"
        PlanMockProtocol.data = Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"한글\"}\n\ndata: {\"type\":\"response.completed\"}\n\n".utf8)
        let body = PlanRequest(model: "fixture", instructions: "test", input: [.init(role: "user", content: [.init(type: "input_text", text: "test")])])
        let before = PlanMockProtocol.count
        let completed = try await ChatGPTPlanTransport.stream(request: body, token: "fixture-only", http: transport) { _ in }
        try check(completed.status == .completed && completed.text == "한글" && PlanMockProtocol.count == before + 1, "real transport consumes completed SSE without replay")
        PlanMockProtocol.data = Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n".utf8)
        let interrupted = try await ChatGPTPlanTransport.stream(request: body, token: "fixture-only", http: transport) { _ in }
        try check(interrupted.status == .interrupted && interrupted.text == "partial", "HTTP EOF preserves partial and never claims completion")
        var cancelledTask: Task<PlanStreamAccumulator, Error>!
        var cancelledStatus: AnswerStatus?
        cancelledTask = Task {
            try await ChatGPTPlanTransport.stream(request: body, token: "fixture-only", http: transport) { partial in
                cancelledStatus = partial.status
                cancelledTask.cancel()
            }
        }
        do { _ = try await cancelledTask.value; throw NSError(domain: "cancel must fail", code: 1) }
        catch { try check(cancelledStatus == .cancelled, "cancelled stream preserves cancellation status and ignores completion") }
        PlanMockProtocol.status = 429; PlanMockProtocol.contentType = "application/json"
        PlanMockProtocol.data = Data(#"{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}"#.utf8)
        let quotaBefore = PlanMockProtocol.count
        do { _ = try await ChatGPTPlanTransport.stream(request: body, token: "fixture-only", http: transport) { _ in }; throw NSError(domain: "quota must fail", code: 1) }
        catch let error as PlanFailure { try check(error.kind == .limit && PlanMockProtocol.count == quotaBefore + 1, "HTTP 429 is classified and never automatically retried") }
        print("\(count)/\(count) session checks passed; no real account/network used")
    }
}
