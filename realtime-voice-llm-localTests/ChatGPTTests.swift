import Foundation
import Security
import Testing
@testable import realtime_voice_llm_local

struct ChatGPTTests {
    @Test func pkceMatchesRFC7636Vector() {
        #expect(OAuthSecurity.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(String(data: OAuthSecurity.form(["a": "a+b &/?"]), encoding: .utf8) == "a=a%2Bb%20%26%2F%3F")
    }
    @Test func callbackRejectsForgeryAndAccountSubstitution() throws {
        let valid = try OAuthSecurity.callback("/auth/callback?code=code&state=expected&client_id=issued", state: "expected", clientID: nil)
        #expect(valid.clientID == "issued")
        #expect(try OAuthSecurity.callback("/auth/callback?code=code&state=expected", state: "expected", clientID: "issued").clientID == "issued")
        for target in ["/auth/callback?code=code&state=wrong&client_id=issued", "/auth/callback?code=code&state=expected", "/auth/callback?code=code&state=expected&client_id=dynamic_agent_client", "/auth/callback?code=code&state=expected&state=expected&client_id=issued", "/auth/callback?error=access_denied&state=expected", "/wrong?code=x&state=expected&client_id=issued"] {
            #expect(throws: (any Error).self) { try OAuthSecurity.callback(target, state: "expected", clientID: nil) }
        }
        #expect(throws: (any Error).self) { try OAuthSecurity.callback("/auth/callback?code=c&state=s&client_id=other", state: "s", clientID: "issued") }
    }
    @Test func identityChecksBindIssuerAccountNonceAudienceAndExpiry() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let claims: [String: Any] = ["iss": OAuthSecurity.issuer, "aud": "issued", "sub": "account", "nonce": "nonce", "exp": 1200.0]
        try OAuthSecurity.validateClaims(claims, clientID: "issued", nonce: "nonce", subject: "account", now: now)
        for (key, value) in [("iss", "https://evil.example" as Any), ("aud", "other"), ("sub", "other"), ("nonce", "wrong"), ("exp", 999.0)] {
            var changed = claims; changed[key] = value
            #expect(throws: (any Error).self) { try OAuthSecurity.validateClaims(changed, clientID: "issued", nonce: "nonce", subject: "account", now: now) }
        }
        let none = OAuthSecurity.base64url(Data(#"{"alg":"none","kid":"k"}"#.utf8)) + "." + OAuthSecurity.base64url(try JSONSerialization.data(withJSONObject: claims)) + ".signature"
        #expect(throws: (any Error).self) { try OAuthSecurity.verifyIDToken(none, jwks: Data(#"{"keys":[]}"#.utf8), clientID: "issued", nonce: "nonce") }
    }
    @Test func signedIdentityMustMatchPublishedKey() throws {
        let key = try #require(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil))
        let publicKey = try #require(SecKeyCopyPublicKey(key))
        let der = try #require(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        var position = 0
        func length() -> Int {
            let first = Int(der[position]); position += 1
            if first < 128 { return first }
            var result = 0
            for _ in 0..<(first & 127) { result = result * 256 + Int(der[position]); position += 1 }
            return result
        }
        position += 1; _ = length()
        position += 1; let nLength = length(); var n = der.subdata(in: position..<(position+nLength)); position += nLength
        if n.first == 0 { n.removeFirst() }
        position += 1; let eLength = length(); let e = der.subdata(in: position..<(position+eLength))
        let jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kty": "RSA", "kid": "test", "n": OAuthSecurity.base64url(n), "e": OAuthSecurity.base64url(e)]]])
        let header = OAuthSecurity.base64url(Data(#"{"alg":"RS256","kid":"test"}"#.utf8))
        let claims: [String: Any] = ["iss": OAuthSecurity.issuer, "aud": "client", "sub": "subject", "nonce": "nonce", "exp": Date().addingTimeInterval(60).timeIntervalSince1970]
        let payload = OAuthSecurity.base64url(try JSONSerialization.data(withJSONObject: claims))
        let unsigned = header + "." + payload
        let signature = try #require(SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(unsigned.utf8) as CFData, nil)) as Data
        let token = unsigned + "." + OAuthSecurity.base64url(signature)
        #expect(try OAuthSecurity.verifyIDToken(token, jwks: jwks, clientID: "client", nonce: "nonce")["sub"] as? String == "subject")
        var tampered = signature; tampered[0] ^= 1
        #expect(throws: (any Error).self) { try OAuthSecurity.verifyIDToken(unsigned + "." + OAuthSecurity.base64url(tampered), jwks: jwks, clientID: "client", nonce: "nonce") }
    }
    @Test func streamFramingPreservesUnicodeAndIgnoresComments() throws {
        var parser = ResponseEvents(); var events: [[String: Any]] = []
        let stream = ": keepalive\r\n\r\nevent: delta\r\ndata: {\"type\":\"response.output_text.delta\",\r\ndata: \"delta\":\"Kia ora 🌏\"}\r\n\r\ndata: {\"type\":\"response.completed\",\"response\":{\"output\":[]}}\n\ndata: [DONE]\n\n"
        for byte in stream.utf8 { if let event = try parser.feed(byte) { events.append(event) } }
        #expect(events.count == 2)
        #expect(events[0]["delta"] as? String == "Kia ora 🌏")
        #expect(events[1]["type"] as? String == "response.completed")
    }
    @Test func requestUsesPlanCompatibleToolsAndSpokenHistory() throws {
        var line = TranscriptLine(role: "assistant", text: "Full reply the user never heard.")
        line.spoken = "Only this part."; line.interrupted = true
        let input = ChatGPTBrain.input(prompt: "Continue", history: [line])
        #expect(input[0]["content"] as? String == "Only this part. [interrupted by user]")
        let body = ChatGPTBrain.requestBody(model: "account-model", input: input, web: false)
        #expect(body["store"] as? Bool == false)
        #expect(body["stream"] as? Bool == true)
        #expect(body["max_output_tokens"] == nil && body["temperature"] == nil)
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools[0]["type"] as? String == "namespace")
        #expect((tools[0]["tools"] as? [[String: Any]])?.count == 2)
        let call = try ChatGPTBrain.toolCall(["type":"function_call", "call_id":"c1", "namespace":"local", "name":"calculate", "arguments":#"{"expression":"37*14"}"#], web: false)
        #expect(LocalTools.argument("expression", in: call) == "37*14")
        #expect(throws: (any Error).self) { try ChatGPTBrain.toolCall(["type":"function_call", "call_id":"c2", "name":"search_web", "arguments":#"{"query":"news"}"#], web: false) }
    }
    @Test func catalogUsesVisibleModelsInServerOrder() throws {
        let models = try ChatGPTAccount.parseModels(Data(#"{"models":[{"slug":"b","display_name":"B","visibility":"list"},{"slug":"hidden","display_name":"Hidden","visibility":"hidden"},{"slug":"a","display_name":"A","visibility":"list"}]}"#.utf8))
        #expect(models.map(\.id) == ["b", "a"])
    }
    @Test func loopbackAcceptsOnlyMatchingTransaction() async throws {
        let listener = OAuthLoopback(state: "correct"); defer { listener.cancel() }
        let port = try await listener.start()
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        let (_, bad) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/auth/callback?state=wrong&code=c&client_id=id")!)
        #expect((bad as? HTTPURLResponse)?.statusCode == 400)
        let target = "/auth/callback?state=correct&code=c&client_id=id"
        let (_, good) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)" + target)!)
        #expect((good as? HTTPURLResponse)?.statusCode == 200)
        #expect(try await listener.value() == target)
    }
    @Test func loopbackCancellationClosesPendingLogin() async throws {
        let listener = OAuthLoopback(state: "cancel")
        _ = try await listener.start(); listener.cancel()
        do { _ = try await listener.value(); Issue.record("Cancelled listener returned a callback") }
        catch { #expect(error is CancellationError) }
    }
}

private final class MockResponses: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let mode = request.value(forHTTPHeaderField: "Authorization") ?? ""
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        let prefix = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello.\"}\n\n"
        client?.urlProtocol(self, didLoad: Data(prefix.utf8))
        if mode.contains("hang") { return }
        if mode.contains("items") {
            let event = #"{"type":"response.output_item.done","output_index":0,"item":{"type":"web_search_call","status":"completed","id":"ws_test"}}"#
            client?.urlProtocol(self, didLoad: Data(("data: " + event + "\n\n").utf8))
            let completed = #"{"type":"response.completed","response":{"output":[]}}"#
            client?.urlProtocol(self, didLoad: Data(("data: " + completed + "\n\n").utf8))
            client?.urlProtocolDidFinishLoading(self); return
        }
        let terminal: String
        if mode.contains("failed") { terminal = #"{"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}}"# }
        else if mode.contains("incomplete") { terminal = #"{"type":"response.incomplete"}"# }
        else if mode.contains("eof") { terminal = "" }
        else { terminal = #"{"type":"response.completed","response":{"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello."}]}]}}"# }
        if !terminal.isEmpty { client?.urlProtocol(self, didLoad: Data(("data: " + terminal + "\n\n").utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockResponses.self]
        return URLSession(configuration: config)
    }
}
struct ChatGPTStreamTests {
    @Test func completedStreamRetainsPreviouslyFinishedOutputItems() async throws {
        let output = try await ChatGPTBrain().stream(body: [:], token: "test-items", session: MockResponses.session(), onToken: { _ in })
        #expect(HostedSearch.completedSearchCount(output) == 1)
    }
    @Test func completedStreamReturnsOutput() async throws {
        let output = try await ChatGPTBrain().stream(body: [:], token: "test-complete", session: MockResponses.session(), onToken: { _ in })
        #expect(output.first?["type"] as? String == "message")
    }
    @Test func partialTextDoesNotHideFailureOrMissingCompletion() async {
        for mode in ["failed", "incomplete", "eof"] {
            do {
                _ = try await ChatGPTBrain().stream(body: [:], token: "test-" + mode, session: MockResponses.session(), onToken: { _ in })
                Issue.record("Accepted a stream without successful completion")
            } catch {
                if mode == "failed" { #expect((error as? ChatGPTAPIError)?.code == "subscription_sharing_usage_limit_exceeded") }
            }
        }
    }
    @Test func interruptionCancelsAnOpenNetworkStream() async throws {
        let started = AsyncStream<Void>.makeStream()
        let task = Task {
            try await ChatGPTBrain().stream(body: [:], token: "test-hang", session: MockResponses.session(), onToken: { _ in started.continuation.yield(()) })
        }
        for await _ in started.stream { break }
        task.cancel(); started.continuation.finish()
        do { _ = try await task.value; Issue.record("Cancelled response completed") }
        catch { #expect(error is CancellationError || (error as? URLError)?.code == .cancelled) }
    }
}

struct ReasoningAndWeatherTests {
    @Test func catalogFiltersUnsupportedEffortsAndDefaultOmitsParameter() throws {
        let data = Data(#"{"models":[{"slug":"test-model","display_name":"Test","visibility":"list","supported_reasoning_levels":[{"effort":"low"},{"effort":"high"},{"effort":"ultra"},{"effort":"low"}]}]}"#.utf8)
        let model = try #require(ChatGPTAccount.parseModels(data).first)
        #expect(model.reasoningLevels == ["low", "high"])
        #expect(model.resolvedEffort("none") == nil)
        #expect(ChatGPTBrain.requestBody(model: model.id, input: [], web: false)["reasoning"] == nil)
        let body = ChatGPTBrain.requestBody(model: model.id, input: [], web: true, reasoningEffort: model.resolvedEffort("low"))
        #expect((body["reasoning"] as? [String: String])?["effort"] == "low")
        #expect(ChatGPTBrain.requestBody(model: model.id, input: [], web: false, reasoningEffort: "ultra")["reasoning"] == nil)
        #expect((body["instructions"] as? String)?.contains(model.id) == true)
    }
    @Test @MainActor func reasoningPersistsPerAccountAndModelWithoutClearingConversation() throws {
        let suite = "LocalVoiceTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let account = ChatGPTAccount(preferences: defaults)
        account.selectedID = "first"
        account.models = [.init(id: "a", name: "A", reasoningLevels: ["low", "high"]), .init(id: "b", name: "B", reasoningLevels: ["medium"])]
        account.chooseModel("a")
        var cleared = false; account.onChange = { cleared = true }
        account.chooseReasoning("low")
        #expect(account.reasoningEffort == "low" && !cleared)
        account.chooseModel("b"); #expect(account.reasoningEffort == nil)
        account.chooseReasoning("low"); #expect(account.reasoningEffort == nil)
        account.chooseModel("a"); #expect(account.reasoningEffort == "low")
        account.selectedID = "second"; account.restoreReasoning(); #expect(account.reasoningEffort == nil)
        account.selectedID = "first"; account.models[0].reasoningLevels = ["high"]
        account.restoreReasoning(); #expect(account.reasoningChoice == "default")
        account.models[0].reasoningLevels = ["low", "high"]; account.restoreReasoning()
        account.chooseReasoning("default"); #expect(account.reasoningEffort == nil)
        let restored = ChatGPTAccount(preferences: defaults)
        restored.selectedID = "first"; restored.models = account.models; restored.chooseModel("a")
        #expect(restored.reasoningChoice == "default")
    }
    @Test func weatherKeepsDatesUnitsAndMissingValues() throws {
        let fixture: [String: Any] = ["timezone":"Pacific/Auckland", "current":["time":"2026-11-08T09:00", "temperature_2m":18.2, "weather_code":3], "current_units":["temperature_2m":"°C"], "daily":["time":["2026-11-08", "2026-11-09"], "temperature_2m_max":[20.0, 21.0], "precipitation_probability_max":[NSNull(), 60] as [Any], "weather_code":[3, 61]], "daily_units":["precipitation_probability_max":"%"]]
        let result = try WeatherTool.format(fixture, location: "Auckland, New Zealand")
        let parsed = try #require(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        #expect(parsed["timezone"] as? String == "Pacific/Auckland")
        #expect((parsed["current"] as? [String: Any])?["conditions"] as? String == "Overcast")
        let days = try #require(parsed["daily"] as? [[String: Any]])
        #expect(days[0]["precipitation_probability_max"] is NSNull)
        #expect(days[1]["date"] as? String == "2026-11-09")
        #expect(days[1]["conditions"] as? String == "Slight rain")
        #expect(throws: (any Error).self) { try WeatherTool.format([:], location: "Auckland") }
    }
    @Test func weatherUsesExplicitCountryAndHonoursWebPermission() async throws {
        let url = try WeatherTool.geocodingURL(location: "Auckland", countryCode: "nz")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "countryCode" })?.value == "NZ")
        #expect(throws: (any Error).self) { try WeatherTool.forecastURL(latitude: .nan, longitude: 174.7) }
        let item: [String: Any] = ["type":"function_call", "call_id":"weather", "namespace":"local", "name":"get_weather", "arguments":#"{"location":"Auckland","country_code":"NZ"}"#]
        let call = try ChatGPTBrain.toolCall(item, web: true)
        #expect(try await LocalTools.execute(call, webEnabled: false) == "Web access is disabled.")
        #expect(throws: (any Error).self) { try ChatGPTBrain.toolCall(item, web: false) }
        let tools = LocalTools.specifications(web: true)
        #expect(tools.count == 5)
    }
}

struct HostedWebSearchTests {
    @Test func searchProviderNeverBypassesWebPermission() throws {
        let native = ChatGPTBrain.requestBody(model: "test", input: [], web: true, reasoningEffort: "low", searchProvider: .model)
        let tools = try #require(native["tools"] as? [[String: Any]])
        #expect(tools.contains { $0["type"] as? String == "web_search" })
        let local = try #require(tools.first?["tools"] as? [[String: Any]])
        #expect(local.compactMap { $0["name"] as? String } == ["get_current_time", "calculate"])
        let off = ChatGPTBrain.requestBody(model: "test", input: [], web: false, searchProvider: .model)
        #expect((off["tools"] as? [[String: Any]])?.count == 1)
        let probe = HostedSearch.request(model: "test", effort: "low")
        #expect(probe["tool_choice"] as? String == "required")
        #expect((probe["reasoning"] as? [String: String])?["effort"] == "low")
    }
    @Test func supportRequiresCompletedSearchInsteadOfModelClaims() {
        let claims: [[String: Any]] = [["type":"message", "content":[["text":"Yes, I can browse."]]], ["type":"web_search_call", "status":"failed"]]
        #expect(HostedSearch.completedSearchCount(claims) == 0)
        #expect(HostedSearch.completedSearchCount(claims + [["type":"web_search_call", "status":"completed"]]) == 1)
    }
    @Test func citationsBecomeClickableAndStayOutOfSpeech() throws {
        let text = "Sunny. citereference"
        let output: [[String: Any]] = [["type":"message", "content":[["text":text, "annotations":[["type":"url_citation", "url":"https://example.com/weather", "title":"Weather source", "start_index":7, "end_index":text.unicodeScalars.count]]]]]]
        let sources = HostedSearch.citations(output)
        #expect(sources.count == 1)
        var line = TranscriptLine(role: "assistant", text: text); line.citations = sources
        #expect(String(line.attributedText.characters) == "Sunny.  [1]")
        #expect(line.attributedText.runs.contains { $0.link?.absoluteString == "https://example.com/weather" })
        var spoken = SpokenTextFilter()
        #expect(spoken.append("Sunny. ci") == "Sunny. ")
        #expect(spoken.append("tereference Enjoy today.") == " Enjoy today.")
        #expect(SpokenTextFilter.comparisonText(text) == SpokenTextFilter.comparisonText("  Sunny.  "))
        let unsafe = TranscriptCitation(start: 0, end: 1, url: "javascript:alert(1)", title: "Bad")
        #expect(unsafe.link == nil)
    }
    @Test @MainActor func providerSelectionRequiresFreshCheckForExactAccountModelAndEffort() throws {
        let suite = "HostedWebTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let account = ChatGPTAccount(preferences: defaults); account.selectedID = "first"
        account.models = [.init(id: "test", name: "Test", reasoningLevels: ["low", "high"])]; account.chooseModel("test"); account.chooseReasoning("low")
        account.chooseWebSearch(.model); #expect(account.effectiveSearchProvider == .appTools)
        account.webChecks["first|test|low"] = .init(model: "test", effort: "low", passed: true, seconds: 2, date: Date(), detail: "Verified")
        account.chooseWebSearch(.model); #expect(account.effectiveSearchProvider == .model)
        account.chooseReasoning("high"); #expect(account.effectiveSearchProvider == .appTools)
        account.chooseReasoning("low"); #expect(account.effectiveSearchProvider == .model)
        account.selectedID = "other"; account.restoreReasoning(); #expect(account.effectiveSearchProvider == .appTools)
        account.selectedID = "first"; account.restoreReasoning()
        account.webChecks["first|test|low"] = .init(model: "test", effort: "low", passed: true, seconds: 2, date: Date(timeIntervalSinceNow: -8 * 86400), detail: "Expired")
        #expect(account.effectiveSearchProvider == .appTools)
    }
}
