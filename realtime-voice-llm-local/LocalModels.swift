import Foundation
import MLXLLM
import MLXLMCommon
import Tokenizers
import FluidAudio
import CoreML

struct VoiceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct TranscriptLine: Identifiable, Codable, Sendable {
    var id = UUID()
    let role: String
    var text: String
    var spoken = ""
    var interrupted = false
    var date = Date()
}

struct PhraseBuffer {
    private(set) var text = ""
    mutating func append(_ delta: String) -> [String] {
        text += delta
        var phrases: [String] = []
        while let cut = boundary() {
            let phrase = String(text[...cut]).trimmingCharacters(in: .whitespacesAndNewlines)
            text = String(text[text.index(after: cut)...])
            if !phrase.isEmpty { phrases.append(phrase) }
        }
        return phrases
    }
    private func boundary() -> String.Index? {
        for i in text.indices {
            let count = text.distance(from: text.startIndex, to: i)
            let c = text[i]
            let next = text.index(after: i)
            if ".!?\n".contains(c), count >= 12,
               next == text.endIndex || text[next].isWhitespace { return i }
            if count >= 60, ",;: ".contains(c) { return i }
        }
        return nil
    }
    mutating func finish() -> String {
        defer { text = "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct LocalTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(upstream: try await AutoTokenizer.from(modelFolder: directory))
    }
}
struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws -> [Int] {
        // A lone user message is an incremental turn with the system/tools
        // already in the KV cache. Avoid reinserting the tool system prompt.
        let incremental = messages.count == 1 && messages.first?["role"] as? String == "user"
        return try upstream.applyChatTemplate(messages: messages, tools: incremental ? nil : tools, additionalContext: additionalContext)
    }
}

actor LocalBrain {
    private var model: ModelContainer?
    private var cachedSession: ChatSession?
    private var cachedHistory: [String] = []
    private var cachedWeb = false
    private var cachedTurns = 0
    private var requestID = UUID()
    private(set) var lastPerformance = ""
    private func historyKey(_ history: [TranscriptLine]) -> [String] {
        history.map { $0.role + ":" + $0.text + ($0.interrupted ? " [interrupted]" : "") }
    }
    static let modelID = "mlx-community/Qwen3.5-4B-MLX-4bit"
    static var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalVoice/Models", isDirectory: true)
    }
    func load(status: @escaping @Sendable (String) -> Void) async throws {
        guard model == nil else { return }
        let directory = Self.modelsDirectory.appendingPathComponent("Qwen3.5-4B-4bit")
        try await ModelDownload.ensureModel(id: Self.modelID, directory: directory, status: status)
        status("Loading Qwen3.5 into memory…")
        model = try await LLMModelFactory.shared.loadContainer(from: directory, using: LocalTokenizerLoader())
    }
    func respond(prompt: String, history: [TranscriptLine], webEnabled: Bool,
                 onToken: @escaping @Sendable (String) async -> Void,
                 onTool: @escaping @Sendable (String) async -> Void) async throws {
        guard let model else { throw VoiceError("The language model is not loaded yet.") }
        var previous: [Chat.Message] = []
        var remaining = 7000
        for line in history.suffix(12).reversed() where line.role != "tool" {
            let content = line.role == "assistant" && line.interrupted ? line.spoken + " [interrupted by user]" : line.text
            guard !content.isEmpty, remaining > 0 else { continue }
            let clipped = String(content.prefix(min(1500, remaining)))
            remaining -= clipped.count
            previous.insert(line.role == "user" ? .user(clipped) : .assistant(clipped), at: 0)
        }
        let instructions = VoiceInstructions.text + " Your text model is Qwen3.5 4B, running locally on this Mac."
        let key = historyKey(history)
        let reuse = cachedSession != nil && cachedHistory == key && cachedWeb == webEnabled && cachedTurns < 4
        var reusableSession = reuse ? cachedSession : nil
        let nextCacheTurns = reuse ? cachedTurns + 1 : 1
        cachedSession = nil
        requestID = UUID(); let request = requestID
        var fullAnswer = ""
        let budget = ToolBudget()
        var messages: [Chat.Message] = [.system(instructions)] + previous + [.user(prompt)]
        let specs = LocalTools.specifications(web: webEnabled)
        // Qwen3.5's template requires a user message even after a tool result.
        // Rebuild each tool pass with the complete structured exchange instead
        // of asking ChatSession to template a standalone tool message.
        for _ in 0..<5 {
            try Task.checkCancellation()
            let usingCache = reusableSession != nil
            let session = reusableSession ?? ChatSession(model,
                generateParameters: .init(maxTokens: 320, temperature: 0.65, topP: 0.85, repetitionPenalty: 1.08),
                additionalContext: ["enable_thinking": false], tools: specs)
            reusableSession = nil
            var calls: [ToolCall] = []
            var content = ""
            do {
                for try await item in session.streamDetails(to: usingCache ? [.user(prompt)] : messages) {
                    try Task.checkCancellation()
                    switch item {
                    case .chunk(let token): content += token; fullAnswer += token; await onToken(token)
                    case .toolCall(let call): calls.append(call)
                    case .info(let info): lastPerformance = "Prompt: \(info.promptTokenCount) tokens in \(info.promptTime)s. Generation: \(info.tokensPerSecond) tokens/s. Reused context: \(usingCache)."
                    }
                }
                await session.synchronize()
            } catch {
                await session.synchronize()
                throw error
            }
            guard !calls.isEmpty else {
                if requestID == request {
                    cachedSession = session
                    cachedHistory = key + ["user:" + prompt, "assistant:" + fullAnswer]
                    cachedWeb = webEnabled; cachedTurns = nextCacheTurns
                }
                return
            }
            messages.append(.assistant(content, toolCalls: calls))
            for call in calls {
                try Task.checkCancellation()
                guard await budget.take() else { throw VoiceError("The tool limit for this reply was reached. Please try a more specific request.") }
                await onTool(LocalTools.label(for: call))
                let result = try await LocalTools.execute(call, webEnabled: webEnabled)
                messages.append(.tool(result, id: call.id))
            }
            if !content.isEmpty { fullAnswer += " "; await onToken(" ") }
        }
        throw VoiceError("The tool limit for this reply was reached.")
    }
}
actor ToolBudget {
    private var remaining = 4
    func take() -> Bool { guard remaining > 0 else { return false }; remaining -= 1; return true }
}

enum ModelDownload {
    struct Manifest: Decodable {
        let sha: String
        let siblings: [Entry]
        struct Entry: Decodable { let rfilename: String; let size: Int64? }
    }
    static func ensureModel(id: String, directory: URL, status: @escaping @Sendable (String) -> Void) async throws {
        let fm = FileManager.default
        let receipt = directory.appendingPathComponent("download-complete.json")
        if let data = try? Data(contentsOf: receipt), let entries = try? JSONDecoder().decode([String: Int64].self, from: data),
           !entries.isEmpty, entries.allSatisfy({ name, size in
               (try? fm.attributesOfItem(atPath: directory.appendingPathComponent(name).path)[.size] as? NSNumber)?.int64Value == size
           }) { return }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        status("Checking Qwen3.5 model download…")
        let (data, response) = try await URLSession.shared.data(from: URL(string: "https://huggingface.co/api/models/\(id)?blobs=true")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw VoiceError("Could not reach Hugging Face to download Qwen. Check your connection and retry.") }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        let entries = manifest.siblings.filter { e in
            !e.rfilename.contains("/") && ([".safetensors", ".json", ".jinja", ".txt"].contains { e.rfilename.hasSuffix($0) })
        }
        guard entries.contains(where: { $0.rfilename.hasSuffix(".safetensors") }) else { throw VoiceError("Model download does not contain weights.") }
        var sizes: [String: Int64] = [:]
        for entry in entries {
            try Task.checkCancellation()
            let destination = directory.appendingPathComponent(entry.rfilename)
            let size = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value
            if let expected = entry.size, size == expected { sizes[entry.rfilename] = expected; continue }
            status("Downloading Qwen: \(entry.rfilename)…")
            let url = URL(string: "https://huggingface.co/\(id)/resolve/\(manifest.sha)/\(entry.rfilename)")!
            var request = URLRequest(url: url); request.timeoutInterval = 1800
            let (temp, result) = try await URLSession.shared.download(for: request)
            guard (result as? HTTPURLResponse)?.statusCode == 200 else { throw VoiceError("Download failed for \(entry.rfilename). Retry to resume setup.") }
            let downloaded = (try fm.attributesOfItem(atPath: temp.path)[.size] as! NSNumber).int64Value
            if let expected = entry.size, expected != downloaded { throw VoiceError("Incomplete model download. Please retry.") }
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: temp, to: destination)
            sizes[entry.rfilename] = downloaded
        }
        try JSONEncoder().encode(sizes).write(to: receipt, options: .atomic)
    }
}
