import Foundation
import Security

struct PlanTokens: Codable {
    var access_token: String
    var refresh_token: String?
    var id_token: String?
    var token_type: String
    var expires_in: Double
    var scope: String
    var earliest_refresh_at: RefreshTime?
    enum RefreshTime: Codable {
        case number(Double), string(String)
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let number = try? value.decode(Double.self) { self = .number(number) } else { self = .string(try value.decode(String.self)) }
        }
        func encode(to encoder: Encoder) throws {
            var value = encoder.singleValueContainer()
            switch self { case .number(let n): try value.encode(n); case .string(let s): try value.encode(s) }
        }
        var date: Date? {
            switch self { case .number(let n): return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
            case .string(let s): return ISO8601DateFormatter().date(from: s) }
        }
    }
    var permitsPlan: Bool { scope.split(separator: " ").contains("chatgpt.tokens.use.direct") }
}
struct PlanRegistration: Codable, Identifiable {
    var id: String // Issued client ID, never an email or dynamic_agent_client.
    var identity: OpenAIIdentity?
    var tokens: PlanTokens?
    var receivedAt: Date?
    var pendingRotation: PlanTokens?
    var pendingReceivedAt: Date?
    var welcomed: Bool?
}
struct PlanVaultState: Codable {
    var hostID = "urn:uuid:" + UUID().uuidString.lowercased()
    var selected: String?
    var pendingClient: String?
    var registrations: [PlanRegistration] = []
}

protocol PlanVault {
    func read() throws -> PlanVaultState
    func write(_ state: PlanVaultState) throws
}
struct KeychainPlanVault: PlanVault {
    private let service = (Bundle.main.bundleIdentifier ?? "note.margin") + ".chatgpt.oauth"
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "registrations-v1"] }
    func read() throws -> PlanVaultState {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { let state = PlanVaultState(); try write(state); return state }
        guard status == errSecSuccess, let data = result as? Data else { throw OAuthAttempt.invalid }
        return try JSONDecoder().decode(PlanVaultState.self, from: data)
    }
    func write(_ state: PlanVaultState) throws {
        let data = try JSONEncoder().encode(state)
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; attributes.forEach { q[$0.key] = $0.value }
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw OAuthAttempt.invalid }
        } else if status != errSecSuccess { throw OAuthAttempt.invalid }
    }
}

struct OpenAIDiscovery: Decodable {
    let issuer: String
    let jwks_uri: URL
    let revocation_endpoint: URL
    func validate() throws {
        guard issuer == "https://auth.openai.com" else { throw OAuthAttempt.invalid }
        for url in [jwks_uri, revocation_endpoint] {
            guard url.scheme == "https", url.host == "auth.openai.com" else { throw OAuthAttempt.invalid }
            guard url.user == nil, url.password == nil else { throw OAuthAttempt.invalid }
        }
    }
}

/// No cookies, URL cache, cross-origin credential redirects or automatic replay.
final class PlanHTTP: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = PlanHTTP()
    private let injectedSession: URLSession?
    init(session: URLSession? = nil) { injectedSession = session; super.init() }
    lazy var session: URLSession = {
        if let injectedSession { return injectedSession }
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil; c.httpShouldSetCookies = false; c.urlCache = nil
        c.timeoutIntervalForRequest = 45; c.timeoutIntervalForResource = 600
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func data(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OAuthAttempt.invalid }
        guard (200..<300).contains(http.statusCode) else { throw PlanFailure.decode(data, status: http.statusCode, requestID: http.value(forHTTPHeaderField: "x-request-id")) }
        return data
    }
    func form(_ url: URL, fields: [String: String]) async throws -> Data {
        var request = URLRequest(url: url); request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = fields.sorted { $0.key < $1.key }.map { $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "&").data(using: .utf8)
        return try await data(request)
    }
    func discovery() async throws -> OpenAIDiscovery {
        let data = try await data(URLRequest(url: URL(string: "https://auth.openai.com/.well-known/openid-configuration")!))
        let result = try JSONDecoder().decode(OpenAIDiscovery.self, from: data); try result.validate(); return result
    }
}

@MainActor final class PlanCredentialSession {
    private let vault: PlanVault
    private let http: PlanHTTP
    private var flights: [String: Task<PlanTokens, Error>] = [:]
    private var epochs: [String: UUID] = [:]
    init(vault: PlanVault = KeychainPlanVault(), http: PlanHTTP = .shared) { self.vault = vault; self.http = http }
    func credentials(client: String) async throws -> PlanTokens {
        if let flight = flights[client] { return try await flight.value }
        let state = try vault.read()
        guard let profile = state.registrations.first(where: { $0.id == client }), let tokens = profile.tokens, let received = profile.receivedAt, profile.identity != nil else { throw OAuthAttempt.invalid }
        guard tokens.permitsPlan else { throw PlanFailure(kind: .permission, code: "scope_missing") }
        let expiry = received.addingTimeInterval(tokens.expires_in)
        if profile.pendingRotation == nil && expiry.timeIntervalSinceNow > 90 { return tokens }
        if let earliest = tokens.earliest_refresh_at?.date, earliest > Date(), profile.pendingRotation == nil {
            if expiry > Date() { return tokens }
            throw PlanFailure(kind: .authentication, code: "refresh_not_yet_allowed")
        }
        let epoch = UUID(); epochs[client] = epoch
        let flight = Task { try await self.refresh(profile: profile, epoch: epoch) }
        flights[client] = flight
        defer { if epochs[client] == epoch { flights[client] = nil } }
        return try await flight.value
    }
    private func refresh(profile: PlanRegistration, epoch: UUID) async throws -> PlanTokens {
        var tokens: PlanTokens
        let received: Date
        if let pending = profile.pendingRotation, let at = profile.pendingReceivedAt { tokens = pending; received = at }
        else {
            guard let refresh = profile.tokens?.refresh_token else { throw OAuthAttempt.invalid }
            do {
                let data = try await http.form(URL(string: "https://auth.openai.com/api/accounts/oauth/token")!, fields: ["grant_type": "refresh_token", "client_id": profile.id, "refresh_token": refresh, "resource": "https://api.openai.com/v1"])
                tokens = try JSONDecoder().decode(PlanTokens.self, from: data); received = Date()
            } catch let error as PlanFailure {
                let terminal = ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"]
                if terminal.contains(error.code), epochs[profile.id] == epoch {
                    var state = try vault.read()
                    if let index = state.registrations.firstIndex(where: { $0.id == profile.id }) { state.registrations[index].tokens = nil; try vault.write(state) }
                }
                throw error
            }
            guard epochs[profile.id] == epoch, !Task.isCancelled else { throw CancellationError() }
            // Persist received rotation before JWKS access: never retry a consumed refresh token.
            var state = try vault.read()
            guard let i = state.registrations.firstIndex(where: { $0.id == profile.id }) else { throw OAuthAttempt.invalid }
            state.registrations[i].pendingRotation = tokens; state.registrations[i].pendingReceivedAt = received
            try vault.write(state)
        }
        guard tokens.token_type.lowercased() == "bearer", !tokens.access_token.isEmpty, tokens.expires_in > 0, tokens.refresh_token != nil else { throw OAuthAttempt.invalid }
        if let id = tokens.id_token {
            let discovery = try await http.discovery()
            let keys = try await http.data(URLRequest(url: discovery.jwks_uri))
            _ = try OpenAIIDToken.verify(id, jwks: keys, client: profile.id, nonce: nil, expectedSubject: profile.identity?.subject, now: received)
        } else { tokens.id_token = profile.tokens?.id_token }
        guard epochs[profile.id] == epoch, !Task.isCancelled else { throw CancellationError() }
        var state = try vault.read()
        guard let i = state.registrations.firstIndex(where: { $0.id == profile.id }), state.registrations[i].identity == profile.identity else { throw OAuthAttempt.invalid }
        state.registrations[i].tokens = tokens; state.registrations[i].receivedAt = received
        state.registrations[i].pendingRotation = nil; state.registrations[i].pendingReceivedAt = nil
        try vault.write(state)
        guard tokens.permitsPlan else { throw PlanFailure(kind: .permission, code: "scope_missing") }
        return tokens
    }
    func invalidate(client: String) { epochs[client] = UUID(); flights[client]?.cancel(); flights[client] = nil }
}
