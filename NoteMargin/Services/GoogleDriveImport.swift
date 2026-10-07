import SwiftUI
import AuthenticationServices
import Security

@MainActor
final class GoogleDriveImport: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding, URLSessionTaskDelegate {
    static let shared = GoogleDriveImport()
    @Published private(set) var busy = false
    @Published private(set) var errorMessage: String?
    @Published private var credential: Credential?
    private var attemptID: UUID?
    var isConnected: Bool { credential != nil }
    var account: String { credential?.account ?? "Google 계정" }
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
    struct Credential: Codable { var clientID: String; var tokens: Tokens; var expires: Date; var account: String? }
    private let keychainService: String
    private let configured: (client: String, scheme: String)?
    init(configuration: (client: String, scheme: String)? = GoogleDriveImport.configuration,
         service: String = (Bundle.main.bundleIdentifier ?? "note.margin") + ".google.drive",
         session: URLSession? = nil) {
        configured = configuration; keychainService = service
        super.init()
        if let session { http = session }
        do { try restoreCredential() } catch { errorMessage = error.localizedDescription }
    }
    var configurationMissing: Bool { configured == nil }
    private var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
         kSecAttrAccount as String: "selected-account"]
    }
    private func restoreCredential() throws {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess, let data = value as? Data else { throw DriveImportError.keychain }
        let saved = try JSONDecoder().decode(Credential.self, from: data)
        if saved.clientID == configured?.client { credential = saved }
    }
    func restoreConnection() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            try restoreCredential()
            guard credential != nil else { return }
            try await loadAccount()
            errorMessage = nil
        } catch is CancellationError {} catch { errorMessage = error.localizedDescription }
    }
    func connect(selectAccount: Bool = false) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            _ = try await authorize(selectAccount: selectAccount, picking: false)
            try await loadAccount()
            errorMessage = nil
        } catch is CancellationError {} catch { errorMessage = error.localizedDescription }
    }
    func disconnect() throws {
        guard !busy else { return }
        try clearCredential()
    }
    private func clearCredential() throws {
        let status = SecItemDelete(keychainQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DriveImportError.keychain }
        credential = nil; errorMessage = nil
    }
    private func loadAccount() async throws {
        struct About: Decodable { struct User: Decodable { var emailAddress: String?; var displayName: String? }; var user: User }
        let data = try await authorized(URL(string: "https://www.googleapis.com/drive/v3/about?fields=user(displayName,emailAddress)")!)
        let user = try JSONDecoder().decode(About.self, from: data).user
        guard var updated = credential else { throw DriveImportError.authorization }
        updated.account = user.emailAddress ?? user.displayName
        try saveCredential(updated)
    }
    nonisolated static var configuration: (client: String, scheme: String)? {
        guard let client = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
              !client.isEmpty, !client.contains("$("),
              let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] else { return nil }
        let scheme = client.split(separator: ".").reversed().joined(separator: ".")
        guard types.contains(where: { ($0["CFBundleURLSchemes"] as? [String])?.contains(scheme) == true }) else { return nil }
        return (client, scheme)
    }
    private func authorize(selectAccount: Bool, picking: Bool) async throws -> String {
        guard let config = configured else { throw DriveImportError.configuration }
        let attempt = try GoogleDriveOAuth(clientID: config.client, scheme: config.scheme)
        let id = UUID(); attemptID = id
        defer { if attemptID == id { attemptID = nil; browser = nil; anchor = nil } }
        let url = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { pending in
                continuation = pending
                anchor = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                    .flatMap(\.windows).first(where: \.isKeyWindow)
                guard anchor != nil else { finish(.failure(DriveImportError.authorization)); return }
                let session = ASWebAuthenticationSession(url: attempt.authorization(selectAccount: selectAccount, picking: picking), callbackURLScheme: config.scheme) { [weak self] url, error in
                    Task { @MainActor in
                        guard self?.attemptID == id else { return }
                        if let url { self?.finish(.success(url)) }
                        else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { self?.finish(.failure(CancellationError())) }
                        else { self?.finish(.failure(DriveImportError.authorization)) }
                    }
                }
                session.presentationContextProvider = self
                browser = session
                if !session.start() { finish(.failure(DriveImportError.authorization)) }
            }
        } onCancel: { Task { @MainActor in
            guard self.attemptID == id else { return }
            self.browser?.cancel(); self.finish(.failure(CancellationError()))
        } }
        try Task.checkCancellation()
        let selected = try attempt.callback(url, picking: picking)
        let tokens = try await exchange(["client_id": config.client, "redirect_uri": attempt.redirect.absoluteString,
            "grant_type": "authorization_code", "code": selected.code, "code_verifier": attempt.verifier])
        // Never reuse a previous account's refresh token after choosing an account.
        try Task.checkCancellation()
        try saveCredential(Credential(clientID: config.client, tokens: tokens, expires: Date().addingTimeInterval(tokens.expires_in)))
        return selected.fileID
    }
    func pickPDF(selectAccount: Bool) async throws -> PDFImportContents {
        guard !busy else { throw DriveImportError.authorization }
        busy = true; defer { busy = false }
        let fileID = try await authorize(selectAccount: selectAccount, picking: true)
        try await loadAccount()
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/" + fileID)!
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
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if [400, 401, 403].contains(status) { throw DriveImportError.authorization }
        guard status == 200 else { throw DriveImportError.download(status) }
        let tokens = try JSONDecoder().decode(Tokens.self, from: data)
        guard tokens.token_type.lowercased() == "bearer", !tokens.access_token.isEmpty, tokens.expires_in > 0,
              tokens.scope.map({ Set($0.split(separator: " ").map(String.init)) == [GoogleDriveOAuth.scope] }) ?? true else { throw DriveImportError.authorization }
        return tokens
    }
    private func refresh() async throws {
        guard let credential else { throw DriveImportError.authorization }
        guard let refresh = credential.tokens.refresh_token else {
            try clearCredential(); throw DriveImportError.authorization
        }
        do {
            var tokens = try await exchange(["client_id": credential.clientID, "grant_type": "refresh_token", "refresh_token": refresh])
            tokens.refresh_token = tokens.refresh_token ?? refresh
            try Task.checkCancellation()
            try saveCredential(Credential(clientID: credential.clientID, tokens: tokens, expires: Date().addingTimeInterval(tokens.expires_in), account: credential.account))
        } catch DriveImportError.authorization {
            try clearCredential()
            throw DriveImportError.authorization
        }
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
    private func saveCredential(_ saved: Credential) throws {
        let query = keychainQuery
        let data = try JSONEncoder().encode(saved)
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw DriveImportError.keychain }
        } else if status != errSecSuccess { throw DriveImportError.keychain }
        credential = saved
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
    @ObservedObject private var drive = GoogleDriveImport.shared
    @State private var showingConnection = false
    var body: some View {
        Button(drive.isConnected ? "Google Drive 연결 관리" : "Google Drive 연결", systemImage: "cloud") {
            showingConnection = true
        }.accessibilityIdentifier("pdf-import-google-drive")
            .sheet(isPresented: $showingConnection) { GoogleDriveConnectionView(drive: drive) }
        if drive.isConnected {
            Text(drive.account).font(.footnote).foregroundStyle(.secondary)
            Button("Drive 파일 선택") { start { try await drive.pickPDF(selectAccount: false) } }
                .disabled(drive.busy)
        }
        Text("선택한 PDF만 접근합니다.").font(.footnote).foregroundStyle(.secondary)
    }
}

private struct GoogleDriveConnectionView: View {
    @ObservedObject var drive: GoogleDriveImport
    @Environment(\.dismiss) private var dismiss
    @State private var operation: Task<Void, Never>?
    @State private var localError: String?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(drive.isConnected ? "연결됨" : "연결 안 됨", systemImage: drive.isConnected ? "checkmark.circle" : "cloud")
                    if drive.isConnected { Text(drive.account) }
                    if let error = localError ?? drive.errorMessage { Text(error).foregroundStyle(.red) }
                }
                if drive.configurationMissing {
                    Section("앱 설정 필요") {
                        Text("개발자가 Google Cloud에서 이 앱의 iOS OAuth 클라이언트를 등록해야 합니다.")
                        Text("GOOGLE_CLIENT_ID와 GOOGLE_REVERSED_CLIENT_ID가 누락되었거나 일치하지 않습니다. 앱 빌드 설정을 완료한 버전이 필요합니다.")
                            .font(.footnote)
                    }
                } else {
                    Section {
                        Button(drive.isConnected ? "다시 연결" : "Google에 로그인") {
                            operation = Task { await drive.connect() }
                        }.disabled(drive.busy)
                        Button("다른 Google 계정 연결") {
                            operation = Task { await drive.connect(selectAccount: true) }
                        }.disabled(drive.busy)
                        if drive.isConnected {
                            Button("이 기기에서 연결 해제", role: .destructive) {
                                do { try drive.disconnect() } catch { localError = error.localizedDescription }
                            }.disabled(drive.busy)
                        }
                        if drive.busy { ProgressView("Google 연결 중…") }
                    } footer: { Text("연결 해제는 이 기기의 저장된 연결을 삭제합니다. Google 계정의 접근 허용은 계정 설정에서 철회할 수 있습니다.") }
                }
            }
            .navigationTitle("Google Drive 연결").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { operation?.cancel(); dismiss() } } }
            .task { await drive.restoreConnection() }
            .onDisappear { operation?.cancel() }
        }
    }
}
