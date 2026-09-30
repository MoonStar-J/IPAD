import Foundation
import Security

let planChecks: [CoreCheck] = [
    CoreCheck(name: "OAuth fresh PKCE and exact loopback callback validation") { _ in
        let redirect = URL(string: "http://127.0.0.1:51399/auth/callback")!
        let a = try OAuthAttempt(redirect: redirect), b = try OAuthAttempt(redirect: redirect)
        try expect(a.state != b.state && a.nonce != b.nonce && a.verifier != b.verifier)
        let values = URLComponents(url: a.authorization(hostID: "urn:uuid:" + UUID().uuidString), resolvingAgainstBaseURL: false)!.queryItems!
        try expect(values.first { $0.name == "client_id" }?.value == "dynamic_agent_client")
        try expect(values.first { $0.name == "code_challenge" }?.value != a.verifier)
        let valid = URL(string: redirect.absoluteString + "?state=\(a.state)&code=fixture&client_id=oaiapp_test")!
        let result = try a.callback(valid)
        try expect(result.client == "oaiapp_test")
        try expect(a.exchange(code: result.code, client: result.client)["redirect_uri"] == redirect.absoluteString)
        for url in [valid.absoluteString.replacingOccurrences(of: a.state, with: "bad"), valid.absoluteString + "&state=bad", valid.absoluteString.replacingOccurrences(of: "127.0.0.1", with: "localhost"), valid.absoluteString.replacingOccurrences(of: "oaiapp_test", with: "dynamic_agent_client")] {
            try expectThrows { _ = try a.callback(URL(string: url)!) }
        }
        let returning = try OAuthAttempt(redirect: redirect, registeredClient: "oaiapp_saved")
        try expectThrows { _ = try returning.callback(URL(string: redirect.absoluteString + "?state=\(returning.state)&code=fixture&client_id=oaiapp_other")!) }
        try expectThrows { _ = try OAuthAttempt(redirect: URL(string: "http://localhost:51399/auth/callback")!) }
    },
    CoreCheck(name: "Signed ID tokens require signature issuer audience nonce expiry and original account") { _ in
        let fixture = try SignedTokenFixture()
        let now = Date(), client = "oaiapp_fixture", nonce = "nonce-fixture"
        let claims: [String: Any] = ["iss": "https://auth.openai.com", "sub": "account-one", "aud": client, "nonce": nonce, "exp": now.timeIntervalSince1970 + 300]
        let token = try fixture.sign(claims)
        try expect(OpenAIIDToken.verify(token, jwks: fixture.jwks, client: client, nonce: nonce).subject == "account-one")
        for (field, value) in [("iss", "https://evil.test"), ("aud", "wrong"), ("nonce", "wrong"), ("sub", "account-two")] {
            var changed = claims; changed[field] = value
            try expectThrows { _ = try OpenAIIDToken.verify(fixture.sign(changed), jwks: fixture.jwks, client: client, nonce: nonce, expectedSubject: "account-one") }
        }
        var expired = claims; expired["exp"] = now.timeIntervalSince1970 - 60
        try expectThrows { _ = try OpenAIIDToken.verify(fixture.sign(expired), jwks: fixture.jwks, client: client, nonce: nonce) }
        var pieces = token.split(separator: ".").map(String.init)
        var payload = claims; payload["sub"] = "forged"
        pieces[1] = try JSONSerialization.data(withJSONObject: payload).base64URL
        try expectThrows { _ = try OpenAIIDToken.verify(pieces.joined(separator: "."), jwks: fixture.jwks, client: client, nonce: nonce) }
        pieces[0] = Data(#"{"alg":"none","kid":"fixture"}"#.utf8).base64URL
        try expectThrows { _ = try OpenAIIDToken.verify(pieces.joined(separator: "."), jwks: fixture.jwks, client: client, nonce: nonce) }
    },
    CoreCheck(name: "Plan request allowlist history snapshot and tutor conditions") { _ in
        var chat = sampleConversation(for: Notebook(title: "private notebook"))
        chat.mode = .hints; chat.pinnedConditions = "미적분 사용 금지"
        chat.messages = [.init(role: .user, text: "첫 질문"), .init(role: .assistant, text: "부분 수식 \\(x", status: .interrupted), .init(role: .user, text: "다음 힌트")]
        let request = try PlanRequest.build(chat: chat, model: "gpt-6.1-sol", projectInstructions: "고등학교 범위")
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        try expect(Set(json.keys) == Set(["model", "instructions", "input", "store", "stream"]))
        try expect(json["store"] as? Bool == false && json["stream"] as? Bool == true)
        try expect(request.input.count == 4 && request.input[0].content[1].image_url?.contains(chat.imageData.base64EncodedString()) == true)
        try expect(request.instructions.contains("미적분 사용 금지") && request.instructions.contains(TutorMode.hints.instruction))
        try expect(!request.input.contains { $0.role == "system" })
        try expect(request.input[2].content[0].text?.contains("불완전") == true)
        try expectThrows { _ = try PlanRequest.build(chat: chat, model: "unverified-model", projectInstructions: "") }
        chat.includeImage = false
        try expect(PlanRequest.build(chat: chat, model: "unverified-model", projectInstructions: "").input[0].content.count == 1)
        chat.pinnedConditions = String(repeating: "x", count: 12_000_001)
        try expectThrows { _ = try PlanRequest.build(chat: chat, model: "gpt-6.1-sol", projectInstructions: "") }
    },
    CoreCheck(name: "SSE byte splits UTF8 JSON LaTex CRLF multiline and duplicate final") { _ in
        var parser = SSEDecoder(), stream = PlanStreamAccumulator()
        let delta: [String: Any] = ["type": "response.output_text.delta", "sequence_number": 1, "delta": "한글 \\(x^2\\)"]
        let json = String(data: try JSONSerialization.data(withJSONObject: delta), encoding: .utf8)!
        let wire = ": comment\r\nevent: response.output_text.delta\r\ndata: \(json)\r\n\r\ndata: \(json)\n\ndata: {\n" + #"data: "type":"response.completed","response":{"output":[{"content":[{"type":"output_text","text":"한글 \\(x^2\\)"}]}]}}"# + "\n\n"
        for byte in wire.utf8 { if let event = try parser.feed(byte) { try stream.consume(event) } }
        try expect(stream.status == .completed && stream.text == "한글 \\(x^2\\)")
        stream.end(cancelled: true); try expect(stream.status == .completed)
    },
    CoreCheck(name: "SSE missing completion cancellation incomplete and streaming quota errors") { _ in
        for cancelled in [false, true] {
            var stream = PlanStreamAccumulator()
            try stream.consume(.init(name: "", data: Data(#"{"type":"response.output_text.delta","delta":"partial"}"#.utf8)))
            stream.end(cancelled: cancelled)
            try expect(stream.text == "partial" && stream.status == (cancelled ? .cancelled : .interrupted))
        }
        var quota = PlanStreamAccumulator()
        try quota.consume(.init(name: "", data: Data(#"{"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}}"#.utf8)))
        try expect(quota.status == .failed && quota.failure?.kind == .limit)
        var incomplete = PlanStreamAccumulator()
        try incomplete.consume(.init(name: "", data: Data(#"{"type":"response.incomplete"}"#.utf8)))
        try expect(incomplete.status == .incomplete)
        try expect(PlanFailure.decode(Data(#"{"error":"invalid_grant"}"#.utf8)).kind == .authentication)
        try expect(PlanFailure.decode(Data("gateway non-JSON".utf8), status: 429).kind == .limit)
    },
    CoreCheck(name: "Request failures preserve account readiness but authentication and quota still block") { _ in
        for kind in [PlanFailure.Kind.protocolError, .network, .unsupported, .context, .cancelled] {
            let failure = PlanFailure(kind: kind, code: "fixture")
            try expect(failure.connectionState(after: .ready, duringInference: true) == .ready)
            try expect(failure.connectionState(after: .ready, duringInference: false) == .error)
            try expect(failure.connectionState(after: .disconnected, duringInference: true) == .error)
        }
        for (kind, state) in [(PlanFailure.Kind.authentication, PlanConnectionState.reauthenticationRequired), (.permission, .permissionRequired), (.ineligible, .permissionRequired), (.limit, .rateLimited)] {
            try expect(PlanFailure(kind: kind, code: "fixture").connectionState(after: .ready, duringInference: true) == state)
        }
        let old = try JSONDecoder().decode(PlanDiagnostic.self, from: Data(#"{"code":"not_sse"}"#.utf8))
        try expect(old.contentType == nil && old.summary == "not_sse")
    },
    CoreCheck(name: "SSE BOM empty keepalive malformed event and DONE without completion") { _ in
        var parser = SSEDecoder(), result = PlanStreamAccumulator()
        let wire = "\u{feff}data: {\"type\":\"response.output_text.delta\",\"delta\":\"보존\"}\n\ndata:\n\ndata: [DONE]\n\n"
        for byte in wire.utf8 { if let event = try parser.feed(byte) { try result.consume(event) } }
        try expect(result.text == "보존" && result.status == .interrupted)
        var malformed = PlanStreamAccumulator()
        do { try malformed.consume(.init(name: "", data: Data("{broken".utf8))); throw CocoaError(.fileReadCorruptFile) }
        catch let failure as PlanFailure { try expect(failure.code == "invalid_event") }
    },
    CoreCheck(name: "Each question mode sends its visible template when the draft is empty") { _ in
        try expect(Set(TutorMode.allCases.map(\.defaultQuestion)).count == TutorMode.allCases.count)
        for mode in TutorMode.allCases {
            try expect(!mode.defaultQuestion.isEmpty)
            try expect(mode.question(for: " \n\t") == mode.defaultQuestion)
            try expect(mode.question(for: "  내가 쓴 질문  ") == "내가 쓴 질문")
            var chat = sampleConversation(for: Notebook(title: "Template"))
            chat.mode = mode; chat.includeImage = false
            chat.messages = [.init(role: .user, text: mode.question(for: ""), mode: mode)]
            let request = try PlanRequest.build(chat: chat, model: "fixture", projectInstructions: "")
            try expect(request.input.last?.content.first?.text == mode.defaultQuestion)
            try expect(request.instructions.contains(mode.instruction))
        }
        try expect(TutorMode.hints.defaultQuestion.contains("힌트 하나"))
        try expect(TutorMode.check.defaultQuestion.contains("풀이가 보이지 않으면"))
    },
    CoreCheck(name: "Plan catalog uses models visibility and preserves server order") { _ in
        let catalog = try JSONDecoder().decode(ChatGPTModelCatalog.self, from: Data(#"{"models":[{"slug":"b","display_name":"Beta","visibility":"list"},{"slug":"hidden","display_name":"Hidden","visibility":"hide"},{"slug":"a","display_name":"Alpha","visibility":"list"}]}"#.utf8))
        try expect(catalog.visible.map(\.slug) == ["b", "a"])
        try expectThrows { _ = try JSONDecoder().decode(ChatGPTModelCatalog.self, from: Data(#"{"data":[{"id":"fake"}]}"#.utf8)) }
    },
    CoreCheck(name: "Backward compatible chat stores snapshot source order mode and partial answer without credentials") { repository in
        let notes = MarginChatRepository(root: repository.root.appendingPathComponent("PlanChats"))
        var chat = sampleConversation(for: Notebook(title: "학습"))
        chat.mode = .proof; chat.schemaVersion = 2; chat.accountRegistrationID = "oaiapp_fixture"
        chat.messages = [.init(role: .user, text: "증명해줘", mode: .proof, model: "model"), .init(role: .assistant, text: "가정부터", status: .interrupted)]
        try notes.save(chat)
        let restored = try notes.load(noteID: chat.noteID)[0]
        try expect(restored == chat)
        let json = String(data: try JSONEncoder().encode(restored), encoding: .utf8)!
        for key in ["access_token", "refresh_token", "id_token", "authorization", "Cookie"] { try expect(!json.contains(key)) }
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(chat)) as! [String: Any]
        for key in ["mode", "schemaVersion", "accountRegistrationID"] { old.removeValue(forKey: key) }
        old["messages"] = [["id": UUID().uuidString, "role": "assistant", "text": "old answer", "createdAt": 0]]
        let migrated = try JSONDecoder().decode(MarginConversation.self, from: JSONSerialization.data(withJSONObject: old))
        try expect(migrated.messages[0].status == nil && migrated.imageData == chat.imageData && migrated.rect == chat.rect)
    }
]

struct SignedTokenFixture {
    let key: SecKey
    let jwks: Data
    init() throws {
        key = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil)!
        let data = SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(key)!, nil)! as Data
        var bytes = Array(data), offset = 0
        func field() -> Data {
            offset += 1; var size = Int(bytes[offset]); offset += 1
            if size & 128 != 0 { let count = size & 127; size = 0; for _ in 0..<count { size = size * 256 + Int(bytes[offset]); offset += 1 } }
            let result = Data(bytes[offset..<offset + size]); offset += size; return result
        }
        bytes = Array(field()); offset = 0
        var n = field(); if n.first == 0 { n.removeFirst() }; let e = field()
        jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kty": "RSA", "kid": "fixture", "use": "sig", "alg": "RS256", "n": n.base64URL, "e": e.base64URL]]])
    }
    func sign(_ claims: [String: Any]) throws -> String {
        let h = Data(#"{"alg":"RS256","kid":"fixture"}"#.utf8).base64URL
        let p = try JSONSerialization.data(withJSONObject: claims).base64URL
        let input = h + "." + p
        let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(input.utf8) as CFData, nil)! as Data
        return input + "." + signature.base64URL
    }
}
