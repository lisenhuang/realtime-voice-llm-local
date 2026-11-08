import Foundation

actor SpeechDraftSocket: SpeechDraftEngine {
    private let config: SpeechPreparationConfig
    private let history: [TranscriptLine]
    private let account: ChatGPTAccount
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var previousID: String?
    private var cancelled = false
    private var localToolUses = 0
    init(config: SpeechPreparationConfig, history: [TranscriptLine], account: ChatGPTAccount) {
        self.config = config; self.history = history; self.account = account
    }
    func cancel() {
        cancelled = true; socket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel(); socket = nil; session = nil; previousID = nil
    }
    private func connection() async throws -> URLSessionWebSocketTask {
        guard !cancelled else { throw CancellationError() }
        if let socket { return socket }
        let token = try await account.accessToken(for: config.profile)
        try Task.checkCancellation(); guard !cancelled else { throw CancellationError() }
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/responses")!)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let session = ChatGPTHTTP.session()
        let socket = session.webSocketTask(with: request)
        self.session = session; self.socket = socket; socket.resume()
        return socket
    }
    static func instructions(model: String) -> String {
        VoiceInstructions.context + " Your selected model is \(model). This response chain prepares ONE live spoken user turn. Each LIVE TRANSCRIPT SNAPSHOT is the complete latest transcript of that same turn, not a separate user message. A newer snapshot fully replaces older snapshots, including corrections or changed intent. All assistant drafts after those snapshots were SILENT and have not been heard by the user. Prepare a concise direct reply to the latest snapshot, without mentioning snapshots, drafts, or changes. The app holds all output until the speaker finishes and verifies the final transcript. Use only the provided read-only tools as needed; a partial phrase alone is not a reason to search."
    }
    func run(snapshot: String, onEvent: @escaping @Sendable (DraftEvent) async -> Void) async throws {
        let socket = try await connection()
        let userText = "LIVE TRANSCRIPT SNAPSHOT (replaces all earlier snapshots in this turn):\n" + snapshot
        var input = previousID == nil ? ChatGPTBrain.input(prompt: userText, history: history) : [["role":"user", "content":userText]]
        var textOffset = 0
        for _ in 0..<5 {
            try Task.checkCancellation(); guard !cancelled else { throw CancellationError() }
            var body = ChatGPTBrain.requestBody(model: config.model, input: input, web: config.web, reasoningEffort: config.effort, searchProvider: config.search)
            let extra = config.web && config.search == .model ? " Use built-in web_search for current facts and weather; app search tools are unavailable. Cite only actual sources." : ""
            body["instructions"] = Self.instructions(model: config.model) + extra
            body.removeValue(forKey: "stream"); body["type"] = "response.create"
            if let previousID { body["previous_response_id"] = previousID }
            let output = try await exchange(body: body, socket: socket, onEvent: onEvent)
            await onEvent(.citations(HostedSearch.citations(output, offset: textOffset)))
            textOffset += HostedSearch.textLength(output)
            let calls = output.filter { $0["type"] as? String == "function_call" }
            if calls.isEmpty { return }
            input = []
            for item in calls {
                try Task.checkCancellation(); guard !cancelled else { throw CancellationError() }
                // Bound read-only tool use across all drafts of this utterance.
                localToolUses += 1
                guard localToolUses <= 4 else { throw VoiceError("Preparation reached its tool limit. The final reply will use the normal path.") }
                let call = try ChatGPTBrain.toolCall(item, web: config.web && config.search == .appTools)
                await onEvent(.tool(LocalTools.label(for: call)))
                let result = try await LocalTools.execute(call, webEnabled: config.web)
                input.append(["type":"function_call_output", "call_id":item["call_id"]!, "output":result])
            }
            await onEvent(.text(" ")); textOffset += 1
        }
        throw VoiceError("Preparation reached its tool limit.")
    }
    private func exchange(body: [String: Any], socket: URLSessionWebSocketTask,
                          onEvent: @escaping @Sendable (DraftEvent) async -> Void) async throws -> [[String: Any]] {
        let data = try JSONSerialization.data(withJSONObject: body)
        // Bound a stalled draft, including an idle receive. Cancellation closes
        // the actual socket, so a hanging server cannot block the next turn.
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(45)); socket.cancel(with: .goingAway, reason: nil) } catch { }
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            try await socket.send(.string(String(decoding: data, as: UTF8.self)))
            var items: [Int: [String: Any]] = [:]; var textCount = 0
            while true {
                try Task.checkCancellation()
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .data(let bytes): data = bytes
                case .string(let text): data = Data(text.utf8)
                @unknown default: throw VoiceError("Unknown preparation stream message.")
                }
                guard data.count <= 2_000_000, let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw VoiceError("Invalid preparation stream message.") }
                switch event["type"] as? String {
                case "response.output_text.delta", "response.refusal.delta":
                    if let text = event["delta"] as? String {
                        textCount += text.count
                        guard textCount <= 20000 else { throw VoiceError("The prepared reply was too long.") }
                        await onEvent(.text(text))
                    }
                case "response.web_search_call.in_progress": await onEvent(.tool("Searching with ChatGPT"))
                case "response.output_item.done":
                    if let index = event["output_index"] as? Int, let item = event["item"] as? [String: Any] { items[index] = item }
                case "response.completed":
                    guard let response = event["response"] as? [String: Any], let id = response["id"] as? String, !id.isEmpty else { throw VoiceError("Preparation completed without a response ID.") }
                    previousID = id
                    let output = response["output"] as? [[String: Any]] ?? []
                    return output.isEmpty ? items.keys.sorted().compactMap { items[$0] } : output
                case "error", "response.failed":
                    throw ChatGPTAPIError.from(try JSONSerialization.data(withJSONObject: event["response"] as? [String: Any] ?? event), status: 400)
                case "response.incomplete": throw VoiceError("The prepared reply was incomplete.")
                default: break
                }
            }
        } onCancel: { socket.cancel(with: .goingAway, reason: nil) }
    }
}
