import Foundation
import CryptoKit
import Security

struct GoogleDriveOAuth {
    static let scope = "https://www.googleapis.com/auth/drive.file"
    let clientID: String
    let redirect: URL
    let state: String
    let verifier: String

    init(clientID: String, scheme: String) throws {
        guard clientID.hasSuffix(".apps.googleusercontent.com"), !clientID.contains("$("),
              scheme == clientID.split(separator: ".").reversed().joined(separator: "."),
              let redirect = URL(string: scheme + ":/oauth2redirect") else { throw DriveImportError.configuration }
        self.clientID = clientID; self.redirect = redirect
        func random() throws -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw DriveImportError.authorization }
            return Self.base64(Data(bytes))
        }
        state = try random(); verifier = try random()
    }
    static func base64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    func authorization(selectAccount: Bool) -> URL {
        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        let fields = ["client_id": clientID, "redirect_uri": redirect.absoluteString, "response_type": "code",
                      "scope": Self.scope, "state": state, "code_challenge_method": "S256",
                      "code_challenge": Self.base64(Data(SHA256.hash(data: Data(verifier.utf8)))),
                      "access_type": "offline", "prompt": selectAccount ? "consent select_account" : "consent",
                      "trigger_onepick": "true", "mimetypes": "application/pdf", "allow_multiple": "false"]
        url.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return url.url!
    }
    func callback(_ url: URL) throws -> (code: String, fileID: String) {
        guard url.scheme == redirect.scheme, url.host == redirect.host, url.path == redirect.path,
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { throw DriveImportError.authorization }
        var values = [String: String]()
        for item in query {
            guard values[item.name] == nil, let value = item.value else { throw DriveImportError.authorization }
            values[item.name] = value
        }
        guard values["state"] == state else { throw DriveImportError.authorization }
        if values["error"] == "access_denied" { throw DriveImportError.denied }
        guard values["error"] == nil, let code = values["code"], !code.isEmpty else { throw DriveImportError.authorization }
        if let scope = values["scope"], Set(scope.split(separator: " ").map(String.init)) != [Self.scope] { throw DriveImportError.authorization }
        guard let id = values["picked_file_ids"], !id.isEmpty else { throw CancellationError() }
        guard id.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { throw DriveImportError.selection }
        return (code, id)
    }
}

enum DriveImportError: LocalizedError {
    case configuration, authorization, denied, selection, notPDF, download(Int), keychain
    var errorDescription: String? {
        switch self {
        case .configuration: return "Google Drive 설정 필요: 이 앱의 iOS OAuth Client ID와 반환 URL 스킴을 Xcode 빌드 설정에 등록해 주세요."
        case .authorization: return "Google 연결을 확인하지 못했습니다. 다시 로그인해 주세요."
        case .denied: return "파일 접근 권한이 허용되지 않았습니다. 가져오려면 선택한 PDF의 접근을 허용해 주세요."
        case .selection: return "PDF 파일 하나를 선택해 주세요."
        case .notPDF: return "선택한 파일이 PDF가 아니거나 다운로드가 허용되지 않았습니다."
        case .download(let status): return "Drive에서 파일을 가져오지 못했습니다 (HTTP \(status)). 연결과 파일 권한을 확인하고 다시 선택해 주세요."
        case .keychain: return "Drive 연결 정보를 안전하게 저장하지 못했습니다. 기기 잠금을 해제하고 다시 시도해 주세요."
        }
    }
}
