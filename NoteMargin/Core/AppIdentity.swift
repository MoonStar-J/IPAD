import Foundation

enum AppIdentity {
    static var displayName: String {
        NSLocalizedString("app.name", value: "note margin", comment: "Localized application name")
    }
}

enum AppBuild {
    static let aiConnectionTitle = "ChatGPT 구독 연결"
}
