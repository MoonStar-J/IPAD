import SwiftUI
import AuthenticationServices
import Security

@MainActor
final class GoogleDriveImport: NSObject, ASWebAuthenticationPresentationContextProviding, URLSessionTaskDelegate {
    private var browser: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var anchor: UIWindow?
    private lazy var http: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    struct Tokens: Codable {
        var access_token: String
        var refresh_token: String?
        var expires_in: Double
        var token_type: String
        var scope: String?
    }
    struct Credential: Codable { var clientID: String; var tokens: Tokens; var expires: Date }
    private var credential: Credential?
    static var configuration: (client: String, scheme: String)? {
        guard let client = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
              !client.isEmpty, !client.contains("$("),
              let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] else { return nil }
        let scheme = client.split(separator: ".").reversed().joined(separator: ".")
        guard types.contains(where: { ($0["CFBundleURLSchemes"] as? [String])?.contains(scheme) == true }) else { return nil }
        return (client, scheme)
    }
    func pickPDF(selectAccount: Bool) async throws -> PDFImportContents {
        guard let config = Self.configuration else { throw DriveImportError.configuration }
        let attempt = try GoogleDriveOAuth(clientID: config.client, scheme: config.scheme)
        defer { browser = nil; anchor = nil; http.invalidateAndCancel() }
        let url = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { pending in
                continuation = pending
                anchor = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                    .flatMap(\.windows).first(where: \.isKeyWindow)
                guard anchor != nil else { finish(.failure(DriveImportError.authorization)); return }
                let session = ASWebAuthenticationSession(url: attempt.authorization(selectAccount: selectAccount), callbackURLScheme: config.scheme) { [weak self] url, error in
                    Task { @MainActor in
                        if let url { self?.finish(.success(url)) }
                        else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { self?.finish(.failure(CancellationError())) }
                        else { self?.finish(.failure(DriveImportError.authorization)) }
                    }
                }
                session.presentationContextProvider = self
                browser = session
                if !session.start() { finish(.failure(DriveImportError.authorization)) }
            }
        } onCancel: { Task { @MainActor in self.finish(.failure(CancellationError())); self.browser?.cancel() } }
        try Task.checkCancellation()
        let selected = try attempt.callback(url)
        let tokens = try await exchange(["client_id": config.client, "redirect_uri": attempt.redirect.absoluteString,
            "grant_type": "authorization_code", "code": selected.code, "code_verifier": attempt.verifier])
        // Never reuse a previous account's refresh token after choosing an account.
        credential = Credential(clientID: config.client, tokens: tokens, expires: Date().addingTimeInterval(tokens.expires_in))
        try saveCredential()
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/" + selected.fileID)!
        components.queryItems = [URLQueryItem(name: "fields", value: "name,mimeType,capabilities(canDownload)"), URLQueryItem(name: "supportsAllDrives", value: "true")]
        struct Metadata: Decodable { let name: String; let mimeType: String; let capabilities: Capabilities
            struct Capabilities: Decodable { let canDownload: Bool? } }
        let metadata = try JSONDecoder().decode(Metadata.self, from: await authorized(components.url!))
        guard metadata.mimeType == "application/pdf", metadata.capabilities.canDownload == true else { throw DriveImportError.notPDF }
        components.queryItems = [URLQueryItem(name: "alt", value: "media"), URLQueryItem(name: "supportsAllDrives", value: "true")]
        let bytes = try await authorized(components.url!)
        try Task.checkCancellation()
        return PDFImportContents(title: (metadata.name as NSString).deletingPathExtension, data: bytes)
    }
    private func exchange(_ fields: [String: String]) async throws -> Tokens {
        var form = URLComponents(); form.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, response) = try await http.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw DriveImportError.authorization }
        let tokens = try JSONDecoder().decode(Tokens.self, from: data)
        guard tokens.token_type.lowercased() == "bearer", !tokens.access_token.isEmpty, tokens.expires_in > 0,
              tokens.scope.map({ Set($0.split(separator: " ").map(String.init)) == [GoogleDriveOAuth.scope] }) ?? true else { throw DriveImportError.authorization }
        return tokens
    }
    private func refresh() async throws {
        guard let credential, let refresh = credential.tokens.refresh_token else { throw DriveImportError.authorization }
        var tokens = try await exchange(["client_id": credential.clientID, "grant_type": "refresh_token", "refresh_token": refresh])
        tokens.refresh_token = tokens.refresh_token ?? refresh
        self.credential = Credential(clientID: credential.clientID, tokens: tokens, expires: Date().addingTimeInterval(tokens.expires_in))
        try saveCredential()
    }
    private func authorized(_ url: URL) async throws -> Data {
        if credential?.expires.timeIntervalSinceNow ?? 0 < 30 { try await refresh() }
        func request() -> URLRequest {
            var result = URLRequest(url: url); result.setValue("Bearer " + (credential?.tokens.access_token ?? ""), forHTTPHeaderField: "Authorization"); return result
        }
        var (data, response) = try await http.data(for: request())
        if (response as? HTTPURLResponse)?.statusCode == 401 { try await refresh(); (data, response) = try await http.data(for: request()) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw DriveImportError.download(status) }
        return data
    }
    private func saveCredential() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "note.margin") + ".google.drive",
            kSecAttrAccount as String: "selected-account"]
        let data = try JSONEncoder().encode(credential)
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw DriveImportError.keychain }
        } else if status != errSecSuccess { throw DriveImportError.keychain }
    }
    private func finish(_ result: Result<URL, Error>) { let pending = continuation; continuation = nil; pending?.resume(with: result) }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor ?? UIWindow() }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward credentials to a URL supplied by an error or redirect.
        completionHandler(nil)
    }
}

struct GoogleDriveImportButton: View {
    let start: (@escaping () async throws -> PDFImportContents) -> Void
    var body: some View {
        if GoogleDriveImport.configuration == nil {
            Label("Google Drive 설정 필요", systemImage: "exclamationmark.circle")
            Text("Google Cloud의 iOS OAuth Client ID와 반환 URL 설정이 필요합니다. 설정 후 Google 계정과 Drive 파일 선택 화면이 열립니다.")
                .font(.footnote).foregroundStyle(.secondary)
        } else {
            Button("Google Drive에서 선택", systemImage: "cloud") {
                start { try await GoogleDriveImport().pickPDF(selectAccount: false) }
            }.accessibilityIdentifier("pdf-import-google-drive")
            Button("다른 Google 계정으로 선택") {
                start { try await GoogleDriveImport().pickPDF(selectAccount: true) }
            }
        }
    }
}
