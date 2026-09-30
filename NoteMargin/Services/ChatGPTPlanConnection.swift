import SwiftUI

@MainActor final class ChatGPTPlanConnection: ObservableObject {
    static let shared = ChatGPTPlanConnection()
    @Published private(set) var state: PlanConnectionState = .disconnected
    @Published private(set) var profiles: [PlanRegistrationLabel] = []
    @Published private(set) var selected: String?
    @Published private(set) var models: [ChatGPTModel] = []
    @Published var model = ""
    @Published var notice: String?
    @Published var welcome = false
    @Published private(set) var signingOut = false
    private(set) var generation = UUID()
    private let vault: PlanVault
    let credentials: PlanCredentialSession
    private var signIn: ChatGPTSignIn?
    private var operation: Task<Void, Never>?
    struct PlanRegistrationLabel: Identifiable {
        let id: String
        let title: String
    }
    init(vault: PlanVault = KeychainPlanVault()) {
        self.vault = vault; credentials = PlanCredentialSession(vault: vault)
        reload()
    }
    private func reload() {
        do {
            let saved = try vault.read()
            profiles = saved.registrations.enumerated().map { .init(id: $0.element.id, title: "\($0.element.identity?.email ?? "등록 중인 계정") · \($0.offset + 1)") }
            selected = saved.selected
            let profile = saved.registrations.first { $0.id == selected }
            state = profile?.tokens == nil ? .disconnected : profile?.tokens?.permitsPlan == true ? .ready : .permissionRequired
        } catch { state = .error; notice = "보안 저장소를 열지 못했습니다. 기기를 잠금 해제한 뒤 다시 시도하세요." }
    }
    func connect(newAccount: Bool = false, requestConsent: Bool = false) {
        guard state != .signingIn, !signingOut else { return }
        interruptRequests(); state = .signingIn; notice = nil
        let identity = generation
        operation = Task {
            do {
                var saved = try vault.read()
                let profile = newAccount ? nil : saved.registrations.first { $0.id == (selected ?? saved.pendingClient) }
                if let profile { credentials.invalidate(client: profile.id) }
                let flow = ChatGPTSignIn(); signIn = flow
                let (attempt, code, client) = try await flow.run(hostID: saved.hostID, profile: profile, requestConsent: requestConsent)
                try Task.checkCancellation(); guard generation == identity else { return }
                // Retain the issued registration even if code exchange fails.
                saved = try vault.read()
                if !saved.registrations.contains(where: { $0.id == client }) { saved.registrations.append(PlanRegistration(id: client)) }
                saved.pendingClient = client; try vault.write(saved)
                let data = try await PlanHTTP.shared.form(URL(string: "https://auth.openai.com/api/accounts/oauth/token")!, fields: attempt.exchange(code: code, client: client))
                let tokens = try JSONDecoder().decode(PlanTokens.self, from: data)
                let received = Date()
                guard tokens.token_type.lowercased() == "bearer", !tokens.access_token.isEmpty, tokens.expires_in > 0, let idToken = tokens.id_token else { throw OAuthAttempt.invalid }
                let discovery = try await PlanHTTP.shared.discovery()
                let keys = try await PlanHTTP.shared.data(URLRequest(url: discovery.jwks_uri))
                let verified = try OpenAIIDToken.verify(idToken, jwks: keys, client: client, nonce: attempt.nonce, expectedSubject: profile?.identity?.subject)
                try Task.checkCancellation(); guard generation == identity else { return }
                saved = try vault.read()
                guard let i = saved.registrations.firstIndex(where: { $0.id == client }) else { throw OAuthAttempt.invalid }
                saved.registrations[i].identity = verified; saved.registrations[i].tokens = tokens; saved.registrations[i].receivedAt = received
                saved.registrations[i].pendingRotation = nil; saved.registrations[i].pendingReceivedAt = nil
                welcome = tokens.permitsPlan && saved.registrations[i].welcomed != true
                saved.selected = client; saved.pendingClient = nil; try vault.write(saved); reload()
                if state == .ready { await refreshModels() }
            } catch {
                guard generation == identity else { return }
                reload()
                if !(error is CancellationError) { handle(error) }
            }
            signIn = nil; operation = nil
        }
    }
    func acknowledgeWelcome() {
        do {
            var saved = try vault.read()
            if let i = saved.registrations.firstIndex(where: { $0.id == selected }) { saved.registrations[i].welcomed = true; try vault.write(saved) }
            welcome = false
        } catch { notice = "설정을 저장하지 못했습니다." }
    }
    func cancelSignIn() { operation?.cancel(); signIn?.cancel(); signIn = nil }
    func select(_ client: String) {
        guard !signingOut else { return }
        cancelSignIn(); interruptRequests()
        do { var saved = try vault.read(); guard saved.registrations.contains(where: { $0.id == client }) else { return }; saved.selected = client; try vault.write(saved); reload() }
        catch { handle(error) }
        operation = Task { await refreshModels() }
    }
    func interruptRequests() {
        generation = UUID(); models = []; model = ""
        MarginAIStore.shared.cancelPlanRequests()
    }
    func refreshModels() async {
        guard let client = selected, state != .signingIn, !signingOut else { return }
        let expected = generation
        do {
            let tokens = try await credentials.credentials(client: client)
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.setValue("Bearer " + tokens.access_token, forHTTPHeaderField: "Authorization")
            let data = try await PlanHTTP.shared.data(request)
            let catalog = try JSONDecoder().decode(ChatGPTModelCatalog.self, from: data)
            guard expected == generation, client == selected else { return }
            models = catalog.visible.filter { !$0.slug.isEmpty && !$0.display_name.isEmpty }
            if !models.contains(where: { $0.slug == model }) { model = models.first?.slug ?? "" }
            state = .ready; notice = nil
        } catch { if expected == generation { handle(error) } }
    }
    func logout() {
        guard let client = selected, !signingOut else { return }
        signingOut = true
        cancelSignIn(); interruptRequests(); state = .disconnected
        operation = Task {
            defer { signingOut = false }
            credentials.invalidate(client: client)
            var revoked = false
            do {
                let saved = try vault.read()
                if let p = saved.registrations.first(where: { $0.id == client }), let token = (p.pendingRotation ?? p.tokens)?.refresh_token {
                    let discovery = try await PlanHTTP.shared.discovery()
                    _ = try await PlanHTTP.shared.form(discovery.revocation_endpoint, fields: ["token": token, "token_type_hint": "refresh_token", "client_id": client]); revoked = true
                }
            } catch { /* Local sign-out must succeed without network. */ }
            do {
                var saved = try vault.read()
                if let i = saved.registrations.firstIndex(where: { $0.id == client }) {
                    saved.registrations[i].tokens = nil; saved.registrations[i].pendingRotation = nil
                    saved.registrations[i].pendingReceivedAt = nil; saved.registrations[i].receivedAt = nil
                    try vault.write(saved)
                }
                reload(); notice = revoked ? "로그아웃했습니다. 노트와 대화는 보존됩니다." : "기기에서 로그아웃했습니다. 원격 연결 해제는 확인하지 못했습니다. ChatGPT 설정에서 앱 연결을 해제할 수 있습니다."
            } catch { state = .error; notice = "보안 저장소에서 자격 증명을 지우지 못했습니다. 다시 로그아웃해 주세요." }
        }
    }
    func handle(_ error: Error, duringInference: Bool = false) {
        let failure = error as? PlanFailure ?? PlanFailure(kind: .network, code: "network_error")
        notice = failure.localizedDescription
        state = failure.connectionState(after: state, duringInference: duringInference)
    }
}
