import Foundation
import CryptoKit
import Security

struct OAuthAttempt {
    let state: String
    let nonce: String
    let verifier: String
    let redirect: URL
    let registeredClient: String?
    init(redirect: URL, registeredClient: String? = nil) throws {
        guard redirect.scheme == "http", redirect.host == "127.0.0.1", redirect.path == "/auth/callback", redirect.port != nil, redirect.query == nil, redirect.fragment == nil else { throw Self.invalid }
        self.redirect = redirect; self.registeredClient = registeredClient
        state = try Self.random(); nonce = try Self.random(); verifier = try Self.random()
    }
    static let invalid = PlanFailure(kind: .authentication, code: "oauth_validation")
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw invalid }
        return Data(bytes).base64URL
    }
    func authorization(hostID: String, idTokenHint: String? = nil, requestConsent: Bool = false) -> URL {
        var fields = ["client_id": registeredClient ?? "dynamic_agent_client", "ext_agent_host_id": hostID,
                      "response_type": "code", "redirect_uri": redirect.absoluteString,
                      "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
                      "resource": "https://api.openai.com/v1", "state": state, "nonce": nonce,
                      "code_challenge_method": "S256", "code_challenge": Data(SHA256.hash(data: Data(verifier.utf8))).base64URL]
        if requestConsent { fields["prompt"] = "consent" }
        if registeredClient == nil { fields["agent_name_hint"] = "note margin" }
        if let idTokenHint, registeredClient != nil { fields["id_token_hint"] = idTokenHint }
        var url = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!
        url.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return url.url!
    }
    func callback(_ url: URL) throws -> (code: String, client: String) {
        guard url.scheme == redirect.scheme, url.host == redirect.host, url.port == redirect.port, url.path == redirect.path,
              url.user == nil, url.password == nil, url.fragment == nil,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              Set(items.map(\.name)).count == items.count else { throw Self.invalid }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard values["state"] == state else { throw Self.invalid }
        if values["error"] != nil { throw PlanFailure(kind: .permission, code: "consent_denied") }
        guard let code = values["code"], !code.isEmpty else { throw Self.invalid }
        let client = values["client_id"] ?? registeredClient ?? ""
        guard !client.isEmpty, client != "dynamic_agent_client", client.count <= 512,
              registeredClient == nil || client == registeredClient else { throw Self.invalid }
        return (code, client)
    }
    func exchange(code: String, client: String) -> [String: String] {
        ["grant_type": "authorization_code", "client_id": client, "code": code, "code_verifier": verifier,
         "redirect_uri": redirect.absoluteString, "resource": "https://api.openai.com/v1"]
    }
}

extension Data {
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    init?(base64URL: String) {
        let raw = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: raw + String(repeating: "=", count: (4 - raw.count % 4) % 4))
    }
}

struct OpenAIIdentity: Codable, Equatable {
    let subject: String
    let email: String?
}

/// Uses Apple's RSA signature verification; never trusts a decoded JWT by itself.
enum OpenAIIDToken {
    static func verify(_ token: String, jwks: Data, client: String, nonce: String?, expectedSubject: String? = nil, now: Date = Date()) throws -> OpenAIIdentity {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let h = Data(base64URL: parts[0]), let p = Data(base64URL: parts[1]), let signature = Data(base64URL: parts[2]),
              let header = try JSONSerialization.jsonObject(with: h) as? [String: Any], header["alg"] as? String == "RS256", header["crit"] == nil,
              let kid = header["kid"] as? String,
              let set = try JSONSerialization.jsonObject(with: jwks) as? [String: Any], let keys = set["keys"] as? [[String: Any]],
              let key = keys.first(where: { $0["kid"] as? String == kid && $0["kty"] as? String == "RSA" && $0["alg"] as? String == "RS256" && $0["use"] as? String == "sig" }),
              let n = key["n"] as? String, let e = key["e"] as? String, let modulus = Data(base64URL: n), let exponent = Data(base64URL: e) else { throw OAuthAttempt.invalid }
        let der = tagged(0x30, taggedInteger(modulus) + taggedInteger(exponent))
        guard let publicKey = SecKeyCreateWithData(der as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil),
              SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, Data((parts[0] + "." + parts[1]).utf8) as CFData, signature as CFData, nil),
              let claims = try JSONSerialization.jsonObject(with: p) as? [String: Any], claims["iss"] as? String == "https://auth.openai.com",
              let exp = claims["exp"] as? Double, exp > now.timeIntervalSince1970 - 30,
              let subject = claims["sub"] as? String, !subject.isEmpty else { throw OAuthAttempt.invalid }
        let audience = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard audience.contains(client), (audience.count == 1 || claims["azp"] as? String == client),
              nonce == nil || claims["nonce"] as? String == nonce,
              expectedSubject == nil || expectedSubject == subject,
              (claims["nbf"] as? Double ?? 0) <= now.timeIntervalSince1970 + 30 else { throw OAuthAttempt.invalid }
        return OpenAIIdentity(subject: subject, email: claims["email"] as? String)
    }
    private static func taggedInteger(_ data: Data) -> Data { tagged(2, data.first.map { $0 & 0x80 != 0 } == true ? Data([0]) + data : data) }
    private static func tagged(_ tag: UInt8, _ data: Data) -> Data {
        var length = data.count
        var bytes: [UInt8] = []
        if length < 128 { bytes = [UInt8(length)] }
        else { while length > 0 { bytes.insert(UInt8(length & 255), at: 0); length >>= 8 }; bytes.insert(0x80 | UInt8(bytes.count), at: 0) }
        return Data([tag] + bytes) + data
    }
}
