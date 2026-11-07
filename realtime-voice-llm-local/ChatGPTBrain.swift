import Foundation
import MLXLMCommon

// Incremental SSE framing handles fragmented UTF-8, CRLF, comments and multiline
// data fields. No partial response is considered successful without completion.
struct ResponseEvents {
    private var line = Data()
    private var fields: [String] = []
    private var size = 0
    mutating func feed(_ byte: UInt8) throws -> [String: Any]? {
        size += 1
        guard size <= 2_000_000 else { throw VoiceError("ChatGPT returned an oversized stream event.") }
        if byte != 10 { line.append(byte); return nil }
        if line.last == 13 { line.removeLast() }
        let text = String(decoding: line, as: UTF8.self); line.removeAll(keepingCapacity: true)
        if text.isEmpty {
            let payload = fields.joined(separator: "\n"); fields.removeAll(keepingCapacity: true); size = 0
            guard !payload.isEmpty, payload != "[DONE]" else { return nil }
            guard let object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { throw VoiceError("ChatGPT returned an invalid stream event.") }
            return object
        }
        if text.hasPrefix("data:") { var field = String(text.dropFirst(5)); if field.first == " " { field.removeFirst() }; fields.append(field) }
        return nil
    }
}
actor ChatGPTBrain {
    static func requestBody(model: String, input: [[String: Any]], web: Bool) -> [String: Any] {
        let functions: [[String: Any]] = LocalTools.specifications(web: web).compactMap { spec in
            guard let function = spec["function"] as? [String: any Sendable] else { return nil }
            var definition = function as [String: Any]; definition["type"] = "function"; definition["strict"] = true
            return definition
        }
        return ["model": model, "instructions": VoiceInstructions.text, "input": input, "store": false, "stream": true,
                "include": ["reasoning.encrypted_content"],
                "tools": [["type": "namespace", "name": "local", "description": "Read-only tools run on the user's Mac.", "tools": functions]]]
    }
    static func input(prompt: String, history: [TranscriptLine]) -> [[String: Any]] {
        var input: [[String: Any]] = []
        var remaining = 20000
        for line in history.suffix(20).reversed() where line.role == "user" || line.role == "assistant" {
            let content = line.role == "assistant" && line.interrupted ? line.spoken + " [interrupted by user]" : line.text
            guard !content.isEmpty, remaining > 0 else { continue }
            let text = String(content.prefix(min(4000, remaining))); remaining -= text.count
            input.insert(["role": line.role, "content": text], at: 0)
        }
        input.append(["role": "user", "content": prompt]); return input
    }
    static func toolCall(_ item: [String: Any], web: Bool) throws -> ToolCall {
        guard item["type"] as? String == "function_call", let id = item["call_id"] as? String, !id.isEmpty,
              let name = item["name"] as? String,
              item["namespace"] == nil || item["namespace"] as? String == "local",
              (web ? ["calculate", "get_current_time", "search_web", "read_webpage"] : ["calculate", "get_current_time"]).contains(name),
              let raw = item["arguments"] as? String, raw.utf8.count <= 16000,
              let arguments = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { throw VoiceError("ChatGPT requested an unavailable or invalid tool.") }
        return try JSONDecoder().decode(ToolCall.self, from: JSONSerialization.data(withJSONObject: ["id": id, "function": ["name": name, "arguments": arguments]]))
    }
    func respond(prompt: String, history: [TranscriptLine], webEnabled: Bool, account: ChatGPTAccount, profile: String, model: String,
                 onToken: @escaping @Sendable (String) async -> Void, onTool: @escaping @Sendable (String) async -> Void) async throws {
        var input = Self.input(prompt: prompt, history: history)
        var usedTools = 0
        for _ in 0..<5 {
            try Task.checkCancellation()
            let token = try await account.accessToken(for: profile)
            try Task.checkCancellation()
            let body = Self.requestBody(model: model, input: input, web: webEnabled)
            let output = try await stream(body: body, token: token, onToken: onToken)
            let calls = output.filter { $0["type"] as? String == "function_call" }
            if calls.isEmpty { return }
            input.append(contentsOf: output)
            for item in calls {
                try Task.checkCancellation(); usedTools += 1
                guard usedTools <= 4 else { throw VoiceError("The tool limit for this reply was reached. Please try a more specific request.") }
                let call = try Self.toolCall(item, web: webEnabled)
                await onTool(LocalTools.label(for: call))
                let result = try await LocalTools.execute(call, webEnabled: webEnabled)
                try Task.checkCancellation()
                input.append(["type": "function_call_output", "call_id": item["call_id"]!, "output": result])
            }
            await onToken(" ")
        }
        throw VoiceError("The tool limit for this reply was reached.")
    }
    func stream(body: [String: Any], token: String, session suppliedSession: URLSession? = nil, onToken: @escaping @Sendable (String) async -> Void) async throws -> [[String: Any]] {
        let session = suppliedSession ?? ChatGPTHTTP.session(); defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: OAuthSecurity.resource + "/responses")!)
        request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        return try await withTaskCancellationHandler {
            let (bytes, response) = try await session.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status != 200 {
                var data = Data()
                for try await byte in bytes { try Task.checkCancellation(); data.append(byte); if data.count >= 64000 { break } }
                throw ChatGPTAPIError.from(data, status: status)
            }
            var events = ResponseEvents(); var characters = 0
            for try await byte in bytes {
                try Task.checkCancellation()
                guard let event = try events.feed(byte) else { continue }
                switch event["type"] as? String {
                case "response.output_text.delta", "response.refusal.delta":
                    if let delta = event["delta"] as? String {
                        characters += delta.count
                        guard characters <= 50000 else { throw VoiceError("The reply was too long for a voice conversation. Please ask a shorter question.") }
                        await onToken(delta)
                    }
                case "response.completed":
                    guard let result = event["response"] as? [String: Any], let output = result["output"] as? [[String: Any]] else { throw VoiceError("ChatGPT completed without a valid reply.") }
                    return output
                case "response.failed", "error":
                    let result = event["response"] as? [String: Any] ?? event
                    throw ChatGPTAPIError.from(try JSONSerialization.data(withJSONObject: result), status: 400)
                case "response.incomplete": throw VoiceError("ChatGPT stopped before completing this reply. Please try again.")
                default: break
                }
            }
            throw VoiceError("The ChatGPT connection ended before the reply completed. Please try again.")
        } onCancel: { session.invalidateAndCancel() }
    }
}
