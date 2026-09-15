import Foundation

enum AppIdentity {
    static var displayName: String {
        #if PERSONAL_CHATGPT
        return NSLocalizedString("app.name", value: "note margin", comment: "Localized application name") + " · Personal"
        #else
        return NSLocalizedString("app.name", value: "note margin", comment: "Localized application name")
        #endif
    }
}

enum AppBuild {
    static var aiConnectionTitle: String {
        #if PERSONAL_CHATGPT
        "ChatGPT 로그인 · 채팅"
        #else
        "AI 연결"
        #endif
    }
}
