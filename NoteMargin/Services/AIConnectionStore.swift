import Foundation
import Combine
import Security

enum AIProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAI, gemini
    var id: String { rawValue }
    var title: String { self == .openAI ? "OpenAI" : "Gemini" }
    var defaultModel: String { self == .openAI ? "gpt-5-mini" : "gemini-2.5-flash" }
    var keyManagementURL: URL {
        URL(string: self == .openAI ? "https://platform.openai.com/api-keys" : "https://aistudio.google.com/api-keys")!
    }
}

enum AIConnectionError: LocalizedError {
    case emptyKey, invalidKey, keychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .emptyKey: return "API 키를 입력해 주세요."
        case .invalidKey: return "API 키에 공백이나 줄바꿈이 포함되어 있습니다. 키를 다시 확인해 주세요."
        case .keychain: return "API 키를 안전하게 저장하거나 읽지 못했습니다. iPad 잠금을 해제한 뒤 다시 시도해 주세요."
        }
    }
}

@MainActor
final class AIConnectionStore: ObservableObject {
    static let shared = AIConnectionStore()

    @Published var selectedProvider: AIProvider {
        didSet {
            defaults.set(selectedProvider.rawValue, forKey: "ai.selectedProvider")
            model = defaults.string(forKey: modelKey(selectedProvider)) ?? selectedProvider.defaultModel
        }
    }
    @Published var model: String {
        didSet { defaults.set(model, forKey: modelKey(selectedProvider)) }
    }
    @Published private(set) var configuredProviders: Set<AIProvider> = []
    private let defaults: UserDefaults
    private let keychainService = "com.notemargin.ai-api-key"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let provider = defaults.string(forKey: "ai.selectedProvider").flatMap(AIProvider.init(rawValue:)) ?? .openAI
        selectedProvider = provider
        model = defaults.string(forKey: "ai.model.\(provider.rawValue)") ?? provider.defaultModel
        for provider in AIProvider.allCases {
            if (try? apiKey(for: provider)) != nil { configuredProviders.insert(provider) }
        }
    }

    func apiKey(for provider: AIProvider) throws -> String? {
        var query = keychainQuery(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw AIConnectionError.keychain(status)
        }
        return key
    }

    func saveAPIKey(_ value: String, for provider: AIProvider) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AIConnectionError.emptyKey }
        guard key.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { throw AIConnectionError.invalidKey }
        let query = keychainQuery(provider)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            for (key, value) in attributes { item[key] = value }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AIConnectionError.keychain(status) }
        configuredProviders.insert(provider)
    }

    func removeAPIKey(for provider: AIProvider) throws {
        let status = SecItemDelete(keychainQuery(provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AIConnectionError.keychain(status) }
        configuredProviders.remove(provider)
    }

    private func modelKey(_ provider: AIProvider) -> String { "ai.model.\(provider.rawValue)" }
    private func keychainQuery(_ provider: AIProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: provider.rawValue,
         kSecAttrSynchronizable as String: false]
    }
}
