import AppKit
import Foundation
import Observation

struct ChatGPTModel: Identifiable, Sendable {
    let id: String
    let name: String
    var reasoningLevels: [String] = []
    static let apiReasoningLevels: Set<String> = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
    func resolvedEffort(_ choice: String) -> String? { reasoningLevels.contains(choice) ? choice : nil }
    static func effortLabel(_ effort: String) -> String {
        switch effort {
        case "none": return "None"
        case "minimal": return "Minimal"
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "Extra high"
        case "max": return "Maximum"
        default: return "Model default"
        }
    }
}
struct ChatGPTProfile: Identifiable, Sendable {
    let id: String
    let label: String
    let connected: Bool
}
private struct ChatGPTRegistration: Codable {
    var clientID: String
    var subject: String
    var label: String
    var email: String?
    var access: String?
    var refresh: String?
    var identity: String?
    var expires: Date?
    var scopes: [String]
}
struct ChatGPTAPIError: LocalizedError {
    let status: Int
    let code: String
    var errorDescription: String? {
        switch code {
        case "subscription_sharing_usage_limit_exceeded", "subscription_sharing_usage_unavailable":
            return "Your ChatGPT plan allowance is unavailable or reached its limit. Manage usage in ChatGPT, try later, or select Local Qwen."
        case "invalid_grant", "token_expired", "invalid_token": return "Your ChatGPT session expired. Please sign in again."
        case "access_denied", "insufficient_scope": return "ChatGPT plan access was not granted. Sign in again and enable plan usage, or select Local Qwen."
        default:
            if status == 401 { return "ChatGPT authentication expired or was rejected. Please sign in again." }
            if status == 403 { return "This account or workspace does not allow ChatGPT plan usage in this app. Check eligibility and permissions, or use Local Qwen." }
            if status == 429 { return "ChatGPT is temporarily rate limited. Wait a moment or use Local Qwen." }
            return "ChatGPT could not complete the request (\(status), \(code)). Please try again."
        }
    }
    static func from(_ data: Data, status: Int) -> Self {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let error = object["error"] as? [String: Any]
        // Do not surface arbitrary server text: it could contain credentials.
        let raw = error?["code"] as? String ?? object["error"] as? String ?? "request_failed"
        let code = raw.count < 100 && raw.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) ? raw : "request_failed"
        return Self(status: status, code: code)
    }
}
final class NoAuthRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
enum ChatGPTHTTP {
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config, delegate: NoAuthRedirects(), delegateQueue: nil)
    }
    static func json(_ url: String, form: [String: String]? = nil, bearer: String? = nil) async throws -> Data {
        let session = session(); defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: url)!)
        if let form { request.httpMethod = "POST"; request.httpBody = OAuthSecurity.form(form); request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type") }
        if let bearer { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ChatGPTAPIError.from(data, status: status) }
        return data
    }
}

@Observable @MainActor
final class ChatGPTAccount {
    var profiles: [ChatGPTProfile] = []
    var selectedID: String
    private let preferences: UserDefaults
    var reasoningChoice = "default"
    var webSearchChoice: WebSearchProvider = .appTools
    var webChecks: [String: WebSearchCheck] = [:]
    var testingWeb = false
    var webTestProgress = ""
    var onWebTest: (() -> Void)?
    private var webTestTask: Task<Void, Never>?
    private var webTestID = UUID()
    private func webKey(model: String, effort: String?) -> String { selectedID + "|" + model + "|" + (effort ?? "default") }
    private var currentWebKey: String { webKey(model: modelID, effort: reasoningEffort) }
    var currentWebCheck: WebSearchCheck? { webChecks[currentWebKey] }
    var effectiveSearchProvider: WebSearchProvider { webSearchChoice == .model && currentWebCheck?.isRecentSuccess == true ? .model : .appTools }
    var accountWebChecks: [WebSearchCheck] { webChecks.filter { $0.key.hasPrefix(selectedID + "|") }.map(\.value).sorted { $0.date > $1.date } }
    var selectedModel: ChatGPTModel? { models.first { $0.id == modelID } }
    var reasoningEffort: String? { selectedModel?.resolvedEffort(reasoningChoice) }
    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        selectedID = preferences.string(forKey: "chatGPTProfile") ?? ""
        if let data = preferences.data(forKey: "chatGPTWebChecks"), let checks = try? JSONDecoder().decode([String: WebSearchCheck].self, from: data) { webChecks = checks }
    }
    var models: [ChatGPTModel] = []
    var modelID = ""
    var busy = false
    var canCancel = false
    var message: String?
    var showWelcome = false
    var onChange: (() -> Void)?
    private var registrations: [ChatGPTRegistration] = []
    private var loaded = false
    private var operation: Task<Void, Never>?
    private var receiver: OAuthLoopback?
    private var refreshes: [String: Task<String, Error>] = [:]
    private var generation = UUID()
    var connected: Bool { profiles.first(where: { $0.id == selectedID })?.connected == true }
    var canUse: Bool { connected && !modelID.isEmpty && !busy }
    var modelName: String { models.first(where: { $0.id == modelID })?.name ?? "Choose a model" }
    var accountName: String { profiles.first(where: { $0.id == selectedID })?.label ?? "Not connected" }

    func restore() async {
        guard !loaded else { return }; loaded = true
        do {
            if let data = try OAuthVault.read() { registrations = try JSONDecoder().decode([ChatGPTRegistration].self, from: data) }
            updateProfiles()
            if connected { await loadModels() }
        } catch { message = error.localizedDescription }
    }
    private func save(_ updated: [ChatGPTRegistration]) throws {
        try OAuthVault.write(JSONEncoder().encode(updated))
        registrations = updated; updateProfiles()
    }
    private func updateProfiles() {
        profiles = registrations.map { .init(id: $0.clientID, label: $0.label, connected: $0.access != nil && $0.scopes.contains("chatgpt.tokens.use.direct")) }
    }
    func choose(_ id: String) {
        guard id != selectedID else { return }
        cancelLogin(); onChange?(); models = []; modelID = ""; selectedID = id
        preferences.set(id, forKey: "chatGPTProfile")
        if connected { operation = Task { await loadModels() } }
    }
    func chooseModel(_ id: String) {
        guard models.contains(where: { $0.id == id }), id != modelID else { return }
        cancelWebTest(); onChange?(); modelID = id
        restoreReasoning()
        preferences.set(id, forKey: "chatGPTModel." + selectedID)
    }
    private var reasoningKey: String { "chatGPTReasoning." + selectedID + "." + modelID }
    func restoreReasoning() {
        let saved = preferences.string(forKey: reasoningKey) ?? "default"
        reasoningChoice = selectedModel?.resolvedEffort(saved) == nil ? "default" : saved
        restoreWebSearch()
    }
    func chooseReasoning(_ choice: String) {
        guard choice == "default" || selectedModel?.resolvedEffort(choice) != nil else { return }
        cancelWebTest(); reasoningChoice = choice
        preferences.set(choice, forKey: reasoningKey)
        restoreWebSearch()
    }
    private func restoreWebSearch() {
        webSearchChoice = WebSearchProvider(rawValue: preferences.string(forKey: "chatGPTWebProvider." + currentWebKey) ?? "") ?? .appTools
    }
    func chooseWebSearch(_ provider: WebSearchProvider) {
        guard provider == .appTools || currentWebCheck?.isRecentSuccess == true else { return }
        webSearchChoice = provider
        preferences.set(provider.rawValue, forKey: "chatGPTWebProvider." + currentWebKey)
    }
    func cancelWebTest() {
        webTestID = UUID(); webTestTask?.cancel(); webTestTask = nil; testingWeb = false
    }
    func testWebSearch(allModels: Bool = false) {
        guard connected, !busy, !testingWeb, let selectedModel else { return }
        onWebTest?()
        let targets = allModels ? models : [selectedModel]
        let profile = selectedID; let requestedEffort = reasoningEffort
        let checkID = UUID(); webTestID = checkID; testingWeb = true
        webTestTask = Task {
            defer { if webTestID == checkID { testingWeb = false; webTestTask = nil } }
            for (index, target) in targets.enumerated() {
                guard !Task.isCancelled, webTestID == checkID else { return }
                let effort = requestedEffort.flatMap { target.resolvedEffort($0) }
                webTestProgress = "Testing \(target.name) (\(index + 1)/\(targets.count))…"
                let started = Date()
                var passed = false; var detail = ""
                do {
                    let token = try await accessToken(for: profile)
                    try Task.checkCancellation()
                    let evidence = WebProbeEvents()
                    let output = try await ChatGPTBrain().stream(body: HostedSearch.request(model: target.id, effort: effort), token: token, onToken: { _ in }, onEvent: { await evidence.observe($0) })
                    let events = await evidence.result()
                    let searches = max(HostedSearch.completedSearchCount(output), events.completed)
                    let sources = HostedSearch.citations(output)
                    passed = searches > 0
                    let items = output.map { item in (item["type"] as? String ?? "unknown") + " (" + (item["status"] as? String ?? "no status") + ")" }.joined(separator: ", ")
                    let answer = output.filter { $0["type"] as? String == "message" }.flatMap { $0["content"] as? [[String: Any]] ?? [] }.compactMap { $0["text"] as? String }.joined(separator: " ")
                    detail = passed ? "\(searches) completed web search call(s), \(sources.count) source citation(s)." : "No completed web search call was returned. Returned items: \(items). Citations: \(sources.count). Test reply: \(String(answer.prefix(500))). Events: \(events.names)"
                } catch {
                    if Task.isCancelled || webTestID != checkID { return }
                    detail = "Could not verify web search. " + error.localizedDescription
                }
                guard !Task.isCancelled, webTestID == checkID, selectedID == profile else { return }
                let result = WebSearchCheck(model: target.id, effort: effort ?? "default", passed: passed, seconds: Date().timeIntervalSince(started), date: Date(), detail: detail)
                webChecks[webKey(model: target.id, effort: effort)] = result
                if let data = try? JSONEncoder().encode(webChecks) { preferences.set(data, forKey: "chatGPTWebChecks") }
            }
            webTestProgress = "Web search check finished. Times include model thinking, search and the short answer."
        }
    }
    func signIn(addAccount: Bool = false) {
        guard !busy else { return }
        cancelWebTest(); onChange?(); busy = true; canCancel = true; message = "Finish sign-in in your browser."
        generation = UUID(); let attempt = generation
        let existing = addAccount ? nil : registrations.first(where: { $0.clientID == selectedID })
        operation = Task {
            defer { if generation == attempt { busy = false; canCancel = false; receiver = nil; operation = nil } }
            do {
                let state = try OAuthSecurity.random(), nonce = try OAuthSecurity.random(), verifier = try OAuthSecurity.random()
                let callback = OAuthLoopback(state: state); receiver = callback
                defer { callback.cancel() }
                let port = try await callback.start()
                try Task.checkCancellation()
                let redirect = "http://127.0.0.1:\(port)/auth/callback"
                var host = preferences.string(forKey: "chatGPTHost")
                if host == nil { host = "urn:uuid:" + UUID().uuidString.lowercased(); preferences.set(host, forKey: "chatGPTHost") }
                var fields = ["response_type": "code", "client_id": existing?.clientID ?? "dynamic_agent_client", "ext_agent_host_id": host!, "redirect_uri": redirect, "scope": OAuthSecurity.scopes, "resource": OAuthSecurity.resource, "state": state, "nonce": nonce, "code_challenge": OAuthSecurity.challenge(verifier), "code_challenge_method": "S256"]
                if let existing {
                    fields["id_token_hint"] = existing.identity; fields["login_hint"] = existing.email
                } else { fields["agent_name_hint"] = "Local Voice" }
                var url = URLComponents(string: OAuthSecurity.issuer + "/api/accounts/authorize")!
                url.queryItems = fields.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) }
                guard NSWorkspace.shared.open(url.url!) else { throw VoiceError("Could not open the browser for ChatGPT sign-in.") }
                let target = try await callback.value()
                let result = try OAuthSecurity.callback(target, state: state, clientID: existing?.clientID)
                let data = try await ChatGPTHTTP.json(OAuthSecurity.issuer + "/api/accounts/oauth/token", form: ["grant_type": "authorization_code", "client_id": result.clientID, "code": result.code, "code_verifier": verifier, "redirect_uri": redirect, "resource": OAuthSecurity.resource])
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                guard let identity = object["id_token"] as? String else { throw VoiceError("ChatGPT did not provide an identity token.") }
                let jwks = try await ChatGPTHTTP.json(OAuthSecurity.issuer + "/.well-known/jwks.json")
                let claims = try OAuthSecurity.verifyIDToken(identity, jwks: jwks, clientID: result.clientID, nonce: nonce, subject: existing?.subject)
                try Task.checkCancellation(); guard generation == attempt else { return }
                let email = claims["email"] as? String
                let number = registrations.count + 1
                var record = existing ?? ChatGPTRegistration(clientID: result.clientID, subject: claims["sub"] as! String, label: "\(email ?? "ChatGPT account") · \(number)", email: email, scopes: [])
                try applyTokens(object, to: &record)
                var updated = registrations.filter { $0.clientID != record.clientID }; updated.append(record)
                try save(updated)
                selectedID = record.clientID; preferences.set(selectedID, forKey: "chatGPTProfile")
                message = nil
                if !record.scopes.contains("chatgpt.tokens.use.direct") { throw VoiceError("Signed in, but ChatGPT plan usage was not granted. Continue with ChatGPT again and allow plan usage.") }
                if !preferences.bool(forKey: "chatGPTWelcomeSeen") { showWelcome = true }
                await loadModels()
                NSApp.activate(ignoringOtherApps: true)
            } catch {
                if generation == attempt && !Task.isCancelled { message = error.localizedDescription }
            }
        }
    }
    func cancelLogin() {
        cancelWebTest()
        generation = UUID(); receiver?.cancel(); receiver = nil; operation?.cancel(); operation = nil; busy = false; canCancel = false; message = nil
    }
    func welcomeSeen() { showWelcome = false; preferences.set(true, forKey: "chatGPTWelcomeSeen") }
    private func applyTokens(_ object: [String: Any], to record: inout ChatGPTRegistration) throws {
        guard let access = object["access_token"] as? String, !access.isEmpty,
              (object["token_type"] as? String)?.lowercased() == "bearer",
              let duration = object["expires_in"] as? Double, duration > 0,
              let refresh = object["refresh_token"] as? String, !refresh.isEmpty else { throw VoiceError("ChatGPT returned incomplete credentials. Please sign in again.") }
        record.access = access; record.refresh = refresh; record.expires = Date().addingTimeInterval(duration)
        if let identity = object["id_token"] as? String { record.identity = identity }
        if let scope = object["scope"] as? String { record.scopes = scope.split(separator: " ").map(String.init) }
    }
    func accessToken(for id: String) async throws -> String {
        guard let record = registrations.first(where: { $0.clientID == id }), record.scopes.contains("chatgpt.tokens.use.direct"), let access = record.access else { throw VoiceError("Connect your ChatGPT account and allow plan usage first.") }
        if (record.expires ?? .distantPast).timeIntervalSinceNow > 60 { return access }
        if let task = refreshes[id] { return try await task.value }
        guard let refresh = record.refresh else { throw VoiceError("Please sign in to ChatGPT again.") }
        let task = Task<String, Error> {
            do {
                let data = try await ChatGPTHTTP.json(OAuthSecurity.issuer + "/api/accounts/oauth/token", form: ["grant_type": "refresh_token", "client_id": id, "refresh_token": refresh, "resource": OAuthSecurity.resource])
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                if let identity = object["id_token"] as? String {
                    let jwks = try await ChatGPTHTTP.json(OAuthSecurity.issuer + "/.well-known/jwks.json")
                    _ = try OAuthSecurity.verifyIDToken(identity, jwks: jwks, clientID: id, nonce: nil, subject: record.subject)
                }
                guard let index = registrations.firstIndex(where: { $0.clientID == id && $0.refresh == refresh }) else { throw CancellationError() }
                var updated = registrations; try applyTokens(object, to: &updated[index]); try save(updated)
                return updated[index].access!
            } catch {
                if let failure = error as? ChatGPTAPIError, ["invalid_grant", "invalid_token", "token_expired"].contains(failure.code),
                   let index = registrations.firstIndex(where: { $0.clientID == id && $0.refresh == refresh }) {
                    var updated = registrations; updated[index].access = nil; updated[index].refresh = nil; updated[index].identity = nil
                    try save(updated)
                }
                throw error
            }
        }
        refreshes[id] = task
        defer { refreshes[id] = nil }
        return try await task.value
    }
    func loadModels() async {
        let id = selectedID
        do {
            let token = try await accessToken(for: id)
            let data = try await ChatGPTHTTP.json(OAuthSecurity.resource + "/models", bearer: token)
            let catalog = try Self.parseModels(data)
            try Task.checkCancellation(); guard id == selectedID else { return }
            models = catalog
            let saved = preferences.string(forKey: "chatGPTModel." + id)
            modelID = catalog.first(where: { $0.id == saved })?.id ?? catalog.first?.id ?? ""
            restoreReasoning()
            message = catalog.isEmpty ? "No text models are available for this ChatGPT account." : nil
        } catch { if id == selectedID && !Task.isCancelled { message = error.localizedDescription } }
    }
    nonisolated static func parseModels(_ data: Data) throws -> [ChatGPTModel] {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let models = object?["models"] as? [[String: Any]] else { throw VoiceError("ChatGPT returned an unrecognised model catalog.") }
        return models.compactMap { item in
            guard item["visibility"] as? String == "list", let slug = item["slug"] as? String, !slug.isEmpty, let name = item["display_name"] as? String else { return nil }
            // Catalog capabilities are authoritative; app-server-only efforts
            // (for example ultra) are not public Responses effort values.
            let raw = item["supported_reasoning_levels"] as? [[String: Any]] ?? []
            var seen = Set<String>()
            let levels = raw.compactMap { $0["effort"] as? String }.filter { ChatGPTModel.apiReasoningLevels.contains($0) && seen.insert($0).inserted }
            return .init(id: slug, name: name, reasoningLevels: levels)
        }
    }
    func signOut() {
        guard !busy else { return }; onChange?(); cancelLogin()
        let id = selectedID; let refreshTask = refreshes[id]
        busy = true; models = []; modelID = ""
        operation = Task {
            // Wait for a rotating refresh before revoking its latest replacement.
            _ = try? await refreshTask?.value
            let token = registrations.first(where: { $0.clientID == id })?.refresh
            var revoked = token == nil
            if let token {
                for attempt in 0..<2 {
                    do { _ = try await ChatGPTHTTP.json(OAuthSecurity.issuer + "/api/accounts/oauth/revoke", form: ["token": token, "token_type_hint": "refresh_token", "client_id": id]); revoked = true; break }
                    catch { if attempt == 0 { try? await Task.sleep(for: .seconds(1)) } }
                }
            }
            do {
                var updated = registrations
                if let i = updated.firstIndex(where: { $0.clientID == id }) { updated[i].access = nil; updated[i].refresh = nil; updated[i].identity = nil; updated[i].expires = nil }
                try save(updated)
                message = revoked ? "Signed out." : "Signed out locally. Remote revocation was not confirmed. You can disconnect Local Voice in ChatGPT Settings."
            } catch { message = error.localizedDescription }
            busy = false; operation = nil
        }
    }
}
