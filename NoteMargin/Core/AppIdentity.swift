import Foundation

enum AppIdentity {
    static var displayName: String {
        localized("app.name")
    }
}

enum AppBuild {
    static var aiConnectionTitle: String { localized("ChatGPT 구독 연결") }
}

// Use the existing string tables without changing the system language or view identity.
enum AppLanguage: String, CaseIterable, Identifiable {
    case korean = "ko", english = "en"
    static let key = "app.language"
    var id: String { rawValue }
    var title: String { self == .korean ? "한국어" : "English" }
    var locale: Locale { Locale(identifier: rawValue) }
    static var current: Self { Self(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .korean }
    private static let bundles = Dictionary(uniqueKeysWithValues: allCases.map { language in
        let bundle = Bundle.main.path(forResource: language.rawValue, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        return (language, bundle)
    })
    var bundle: Bundle { Self.bundles[self] ?? .main }
}

func localized(_ key: String, _ arguments: String..., language: AppLanguage = .current) -> String {
    let format = language.bundle.localizedString(forKey: key, value: key, table: nil)
    return arguments.isEmpty ? format : String(format: format, locale: language.locale, arguments: arguments)
}

// Keep transient UI messages unresolved until presentation, so an in-flight task
// need not restart just to update its status or error in the selected language.
struct AppMessage: LocalizedError, ExpressibleByStringLiteral {
    private let key: String
    private let arguments: [String]
    private let cause: Error?
    init(_ key: String, _ arguments: String...) {
        self.key = key; self.arguments = arguments; cause = nil
    }
    init(stringLiteral value: String) { self.init(value) }
    init(_ error: Error) { key = ""; arguments = []; cause = error }
    init(_ key: String, error: Error) { self.key = key; arguments = []; cause = error }
    var text: String {
        if let cause {
            let description: String
            let system = cause as NSError
            if AppLanguage.current == .english,
               [NSCocoaErrorDomain, NSURLErrorDomain].contains(system.domain),
               cause.localizedDescription.range(of: "[가-힣]", options: .regularExpression) != nil {
                description = localized("system.error", system.domain, String(system.code))
            } else { description = cause.localizedDescription }
            return key.isEmpty ? description : String(format: localized(key), locale: AppLanguage.current.locale, description)
        }
        let format = localized(key)
        return arguments.isEmpty ? format : String(format: format, locale: AppLanguage.current.locale, arguments: arguments)
    }
    var errorDescription: String? { text }
    var isEmpty: Bool { key.isEmpty && cause == nil }
}
