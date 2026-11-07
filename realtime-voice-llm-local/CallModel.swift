import SwiftUI
import AVFoundation
import FluidAudio
import Observation

enum ModelProvider: String, CaseIterable { case local, chatGPT }

@Observable @MainActor
final class CallModel {
    var provider = ModelProvider(rawValue: UserDefaults.standard.string(forKey: "modelProvider") ?? "") ?? .local
    let chatGPT = ChatGPTAccount()
    let cloudBrain = ChatGPTBrain()
    var canStart: Bool { ready && (provider == .local || chatGPT.canUse) }
    var ready = false
    var preparing = false
    var active = false
    var muted = false
    var webEnabled = true
    var speaking = false
    var thinking = false
    var setupStatus = "Preparing your local models"
    var status = "Getting ready"
    var error: String?
    var partial = ""
    var level: Float = 0
    var microphoneName = "System microphone"
    var echoCancellation = true
    var rawMicrophoneDB: Float = -120
    var microphoneFormat = ""
    var microphoneDB: Float = -120
    var speechProbability: Float = 0
    var microphoneFeedback = "Waiting for microphone audio"
    private var silentInputSeconds = 0.0
    var voice = "af_heart"
    var speed = 1.0
    var pause = 0.9
    var typedText = ""
    var transcript: [TranscriptLine] = []
    var tools: [String] = []
    var responseTime: Double?
    var startedAt: Date?
    var checking = false
    var selfTestStatus: String?
    var selfTestReport = ""
    let brain = LocalBrain()
    let speech = SpeechInput()
    let tts = KokoroAneManager(directory: LocalBrain.modelsDirectory, version: .v3)
    let audio = CallAudio()
    private var captureTask: Task<Void, Never>?
    private var responseTask: Task<Void, Never>?
    private var speechTask: Task<Void, Never>?
    private var phraseContinuation: AsyncStream<String>.Continuation?
    private var turnID = UUID()
    private var callID = UUID()
    private var assistantID: UUID?
    private var requestedAt = Date()
    private var tokenStarted = false
    private var responseFinished = false
    private var synthesisFinished = false
    private var wasSpeakingAtStart = false

    init() {
        chatGPT.onChange = { [weak self] in self?.endCall(); self?.newConversation() }
        audio.onPhrasePlayed = { [weak self] text in
            guard let self, let id = self.assistantID, let i = self.transcript.firstIndex(where: { $0.id == id }) else { return }
            self.transcript[i].spoken += (self.transcript[i].spoken.isEmpty ? "" : " ") + text
        }
        audio.onOutputChanged = { [weak self] value in
            guard let self else { return }
            self.speaking = value
            if value {
                self.status = "Speaking"
                if self.responseTime == nil { self.responseTime = Date().timeIntervalSince(self.requestedAt) }
            } else { self.finishIfIdle() }
        }
        audio.onDeviceChanged = { [weak self] in
            guard let self, self.active else { return }
            self.endCall()
            self.error = "Your audio device changed. Start the call again to use the new microphone and speakers."
        }
    }
    func prepare() async {
        guard !preparing, !ready else { return }
        preparing = true; error = nil
        do {
            let report: @Sendable (String) -> Void = { [weak self] value in
                Task { @MainActor [weak self] in self?.setupStatus = value }
            }
            await chatGPT.restore()
            if provider == .local { try await brain.load(status: report) }
            try await speech.load(status: report)
            setupStatus = "Preparing Kokoro voices. First use can take a few minutes…"
            try await tts.initialize(preloadVoices: ["af_heart", "af_bella", "am_adam", "bf_emma"])
            if provider == .local {
                setupStatus = "Warming up the language model…"
                try await brain.respond(prompt: "Say hello.", history: [], webEnabled: true, onToken: { _ in }, onTool: { _ in })
            }
            setupStatus = "Warming up your voice…"
            _ = try await tts.synthesizeDetailed(text: "Ready when you are.", voice: "af_heart")
            ready = true; status = "Ready when you are"; setupStatus = "Local speech is ready"
        } catch { self.error = error.localizedDescription; status = "Setup needs attention" }
        preparing = false
    }
    func changeProvider(_ selected: ModelProvider) async {
        guard selected != provider, !preparing else { return }
        endCall(); newConversation(); provider = selected
        UserDefaults.standard.set(selected.rawValue, forKey: "modelProvider")
        ready = false
        await prepare()
    }
    func importModel() async {
        guard !preparing, !ready else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a downloaded Qwen3.5-4B MLX model folder"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        do {
            let fm = FileManager.default
            let files = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.fileSizeKey])
                .filter { ["json", "jinja", "safetensors", "txt"].contains($0.pathExtension) && $0.lastPathComponent != "download-complete.json" }
            guard files.contains(where: { $0.lastPathComponent == "config.json" }),
                  files.contains(where: { $0.lastPathComponent == "tokenizer.json" }),
                  files.contains(where: { $0.pathExtension == "safetensors" }) else { throw VoiceError("Choose the complete Qwen3.5-4B MLX model folder, including its tokenizer and weights.") }
            let destination = LocalBrain.modelsDirectory.appendingPathComponent("Qwen3.5-4B-4bit")
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            var receipt: [String: Int64] = [:]
            for file in files {
                let target = destination.appendingPathComponent(file.lastPathComponent)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.copyItem(at: file, to: target)
                receipt[file.lastPathComponent] = (try fm.attributesOfItem(atPath: target.path)[.size] as! NSNumber).int64Value
            }
            try JSONEncoder().encode(receipt).write(to: destination.appendingPathComponent("download-complete.json"), options: .atomic)
            await prepare()
            if ProcessInfo.processInfo.arguments.contains("--self-test"), ready { await IntegrationCheck.run(model: self) }
        } catch { self.error = error.localizedDescription }
    }
    func startCall() async {
        guard canStart, !active, !checking else { return }
        error = nil
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard allowed else { error = "Allow microphone access in System Settings → Privacy & Security → Microphone, then start again."; return }
        if let captureTask { await captureTask.value }
        await speech.reset()
        do {
            let stream = try audio.start(voiceProcessing: echoCancellation)
            microphoneName = audio.inputDescription; microphoneDB = -120
            speechProbability = 0; silentInputSeconds = 0
            microphoneFeedback = "Waiting for microphone audio"
            callID = UUID(); let call = callID
            active = true; muted = false; status = "Listening"; startedAt = Date()
            captureTask = Task { [weak self] in
                guard let self else { return }
                do {
                    for await buffer in stream {
                        try Task.checkCancellation()
                        guard self.callID == call, self.active else { break }
                        self.rawMicrophoneDB = 20 * log10(max(buffer.sourcePeak, 0.000001))
                        self.microphoneFormat = "\(Int(buffer.buffer.format.sampleRate)) Hz · \(buffer.buffer.format.channelCount) channels"
                        try await self.speech.feed(buffer, muted: self.muted, pause: self.pause,
                            onLevel: { [weak self] level in await self?.updateLevel(level, call: call) },
                            onDiagnostics: { [weak self] rms, probability in await self?.updateMicrophone(rms: rms, probability: probability, call: call) },
                            onStart: { [weak self] in await self?.speechStarted(call: call) },
                            onPartial: { [weak self] text in await self?.setPartial(text, call: call) },
                            onFinal: { [weak self] text in await self?.receivedSpeech(text, call: call) })
                    }
                } catch is CancellationError { }
                  catch { if self.callID == call { self.endCall(); self.error = "Microphone processing failed: \(error.localizedDescription)" } }
            }
        } catch { self.error = error.localizedDescription; active = false }
    }
    func endCall() {
        callID = UUID(); active = false; captureTask?.cancel()
        interrupt(mark: true)
        audio.stop(); partial = ""; level = 0; startedAt = nil; status = ready ? "Ready when you are" : "Getting ready"
    }
    func changeEchoCancellation() async {
        guard active else { return }
        endCall()
        await startCall()
    }
    func toggleMute() {
        muted.toggle(); partial = ""; level = 0
        if !speaking && !thinking { status = muted ? "Microphone muted" : "Listening" }
    }
    private func updateMicrophone(rms: Float, probability: Float, call: UUID) {
        guard callID == call, active, !muted else { return }
        microphoneDB = 20 * log10(max(rms, 0.000001))
        speechProbability = probability
        silentInputSeconds = rms < 0.000001 ? silentInputSeconds + 0.256 : 0
        if silentInputSeconds >= 3 {
            microphoneFeedback = "No microphone signal. Check your input device and open the MacBook lid."
        } else if probability >= 0.5 {
            microphoneFeedback = "Hearing speech"
        } else {
            microphoneFeedback = "Microphone connected · speak to begin"
        }
    }
    private func updateLevel(_ value: Float, call: UUID) { if callID == call, !muted { level = value } }
    private func setPartial(_ value: String, call: UUID) { if callID == call, active, !muted { partial = value } }
    private func speechStarted(call: UUID) {
        guard callID == call, active, !muted else { return }
        wasSpeakingAtStart = speaking || thinking
        interrupt(mark: true)
        status = "Listening"; partial = ""
    }
    private func receivedSpeech(_ text: String, call: UUID) {
        guard callID == call, active, !muted else { return }
        partial = ""
        submit(text)
    }
    func sendTyped() {
        let text = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard active, !text.isEmpty else { return }
        typedText = ""; submit(text)
    }
    func submit(_ text: String) {
        guard active else { return }
        interrupt(mark: true)
        let previous = transcript
        transcript.append(TranscriptLine(role: "user", text: text))
        let answer = TranscriptLine(role: "assistant", text: "")
        transcript.append(answer); assistantID = answer.id
        turnID = UUID(); let turn = turnID
        requestedAt = Date(); responseTime = nil; tokenStarted = false
        responseFinished = false; synthesisFinished = false; thinking = true; status = "Thinking"
        let phrases = AsyncStream<String>.makeStream()
        phraseContinuation = phrases.continuation
        let chosenVoice = voice; let chosenSpeed = Float(speed)
        speechTask = Task { [weak self] in
            guard let self else { return }
            do {
                for await phrase in phrases.stream {
                    try Task.checkCancellation()
                    guard self.turnID == turn, self.active else { return }
                    // Bound queued audio so an interruption discards little work.
                    while self.audio.pendingBuffers >= 2 {
                        try await Task.sleep(for: .milliseconds(30))
                        guard self.turnID == turn else { return }
                    }
                    let audio = try await self.tts.synthesizeDetailed(text: phrase, voice: chosenVoice, speed: chosenSpeed)
                    try Task.checkCancellation()
                    guard self.turnID == turn, self.active else { return }
                    try self.audio.enqueue(samples: audio.samples, text: phrase)
                }
                guard self.turnID == turn else { return }
                self.synthesisFinished = true; self.finishIfIdle()
            } catch is CancellationError { }
              catch { if self.turnID == turn { self.error = "Voice playback failed: \(error.localizedDescription)"; self.synthesisFinished = true; self.finishIfIdle() } }
        }
        let chosenReasoning = chatGPT.reasoningEffort
        responseTask = Task { [weak self] in
            guard let self else { return }
            let accumulator = ResponsePhrases()
            do {
                let onToken: @Sendable (String) async -> Void = { [weak self] token in
                    let ready = await accumulator.append(token)
                    await self?.receiveToken(token, phrases: ready, turn: turn)
                }
                let onTool: @Sendable (String) async -> Void = { [weak self] label in await self?.toolStarted(label, turn: turn) }
                if self.provider == .chatGPT {
                    try await self.cloudBrain.respond(prompt: text, history: previous, webEnabled: self.webEnabled,
                        account: self.chatGPT, profile: self.chatGPT.selectedID, model: self.chatGPT.modelID, reasoningEffort: chosenReasoning, onToken: onToken, onTool: onTool)
                } else {
                    try await self.brain.respond(prompt: text, history: previous, webEnabled: self.webEnabled, onToken: onToken, onTool: onTool)
                }
                let last = await accumulator.finish()
                guard self.turnID == turn else { return }
                if !last.isEmpty { self.phraseContinuation?.yield(last) }
                self.phraseContinuation?.finish(); self.phraseContinuation = nil
                self.responseFinished = true; self.thinking = false; self.finishIfIdle()
            } catch is CancellationError { }
              catch {
                guard self.turnID == turn else { return }
                self.error = "Could not finish this reply: \(error.localizedDescription)"
                self.phraseContinuation?.finish(); self.phraseContinuation = nil
                self.responseFinished = true; self.thinking = false; self.finishIfIdle()
            }
        }
    }
    private func receiveToken(_ token: String, phrases: [String], turn: UUID) {
        guard turnID == turn, active, let id = assistantID, let i = transcript.firstIndex(where: { $0.id == id }) else { return }
        transcript[i].text += token; tokenStarted = true
        for phrase in phrases { phraseContinuation?.yield(phrase) }
    }
    private func toolStarted(_ label: String, turn: UUID) {
        guard turnID == turn, active else { return }
        tools.append(label); if tools.count > 12 { tools.removeFirst() }
        if !speaking { status = label.hasPrefix("Searching") || label.hasPrefix("Reading") ? "Searching the web" : "Using a tool" }
    }
    func interrupt(mark: Bool = true) {
        turnID = UUID()
        responseTask?.cancel(); responseTask = nil
        speechTask?.cancel(); speechTask = nil
        phraseContinuation?.finish(); phraseContinuation = nil
        let fragment = audio.interrupt()
        if mark, let id = assistantID, let i = transcript.firstIndex(where: { $0.id == id }),
           !responseFinished || !synthesisFinished || transcript[i].spoken.trimmingCharacters(in: .whitespacesAndNewlines) != transcript[i].text.trimmingCharacters(in: .whitespacesAndNewlines) {
            if !fragment.isEmpty { transcript[i].spoken += (transcript[i].spoken.isEmpty ? "" : " ") + fragment }
            transcript[i].interrupted = true
        }
        assistantID = nil; thinking = false; speaking = false
        responseFinished = true; synthesisFinished = true
        if active { status = muted ? "Microphone muted" : "Listening" }
    }
    private func finishIfIdle() {
        guard active, responseFinished, synthesisFinished, audio.pendingBuffers == 0 else { return }
        speaking = false; thinking = false; status = muted ? "Microphone muted" : "Listening"
    }
    func newConversation() {
        interrupt(); transcript.removeAll(); tools.removeAll(); partial = ""; responseTime = nil
    }
    func copyTranscript() {
        let text = transcript.filter { !$0.text.isEmpty }.map { "\($0.role == "user" ? "You" : "AI"): \($0.text)\($0.interrupted ? " [interrupted]" : "")" }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
}
actor ResponsePhrases {
    private var buffer = PhraseBuffer()
    func append(_ token: String) -> [String] { buffer.append(token) }
    func finish() -> String { buffer.finish() }
}
