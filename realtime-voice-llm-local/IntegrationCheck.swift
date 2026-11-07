import Foundation
import AVFoundation
import FluidAudio

@MainActor
enum IntegrationCheck {
    static func run(model: CallModel) async {
        model.checking = true
        defer { model.checking = false }
        let reportURL = LocalBrain.modelsDirectory.deletingLastPathComponent().appendingPathComponent("integration-check.json")
        var report: [String: Any] = ["date": ISO8601DateFormatter().string(from: Date())]
        do {
            model.status = "Checking local speech"
            let knownText = "Hello, this is a local voice test. The weather is beautiful today."
            let started = Date()
            let audio = try await model.tts.synthesize(text: knownText, voice: "af_heart")
            report["ttsSeconds"] = Date().timeIntervalSince(started)
            let wav = reportURL.deletingLastPathComponent().appendingPathComponent("test-speech.wav")
            try audio.write(to: wav)
            let text = try await model.speech.transcribeFile(wav)
            report["transcription"] = text
            let live = LiveCheckCollector()
            await model.speech.reset()
            // Regression: quiet speech in hardware-rate chunks must survive
            // resampling and the VAD's required 4096-sample windows.
            let original = try AudioConverter().resampleAudioFile(wav) + Array(repeating: Float(0), count: 24000)
            let input = original.flatMap { sample in Array(repeating: sample * 0.08, count: 3) }
            report["liveInputSampleRate"] = 48000
            report["liveInputGain"] = 0.08
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
            for offset in stride(from: 0, to: input.count, by: 1024) {
                let chunk = Array(input[offset..<min(input.count, offset + 1024)])
                let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.count))!
                pcm.frameLength = AVAudioFrameCount(chunk.count)
                chunk.withUnsafeBufferPointer { pcm.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
                try await model.speech.feed(CapturedAudio(buffer: pcm), muted: false, pause: 0.9,
                                           onLevel: { _ in }, onStart: { await live.started() },
                                           onPartial: { await live.partial($0) }, onFinal: { await live.final($0) })
            }
            let liveResult = await live.result()
            report["liveSpeechStarts"] = liveResult.0
            report["livePartialCount"] = liveResult.1
            report["liveFinalTranscripts"] = liveResult.2
            guard liveResult.0 > 0, liveResult.1 > 0, liveResult.2.joined(separator: " ").lowercased().contains("weather") else { throw VoiceError("Live VAD/transcript/end-of-turn check failed.") }
            await model.speech.reset()
            guard text.lowercased().contains("local"), text.lowercased().contains("weather") else { throw VoiceError("Speech round-trip did not recognise the test sentence.") }
            model.status = "Checking local model and tools"
            let collector = CheckCollector()
            let llmStart = Date()
            try await model.brain.respond(prompt: "Use the calculate tool to compute 37 times 14 and tell me the answer in one sentence.", history: [], webEnabled: false,
                                          onToken: { await collector.token($0) }, onTool: { await collector.tool($0) })
            let result = await collector.result()
            report["llmSeconds"] = Date().timeIntervalSince(llmStart)
            report["answer"] = result.0; report["tools"] = result.1
            guard result.0.contains("518"), result.1.contains(where: { $0.contains("Calculating") }) else { throw VoiceError("The model did not correctly complete the tool-call check.") }
            report["llmPerformance"] = await model.brain.lastPerformance
            let followup = CheckCollector()
            let followupStart = Date()
            try await model.brain.respond(prompt: "What was that result? Just repeat the number.",
                history: [TranscriptLine(role: "user", text: "Use the calculate tool to compute 37 times 14 and tell me the answer in one sentence."), TranscriptLine(role: "assistant", text: result.0)],
                webEnabled: false, onToken: { await followup.token($0) }, onTool: { await followup.tool($0) })
            let continued = await followup.result()
            report["cachedFollowupSeconds"] = Date().timeIntervalSince(followupStart)
            report["cachedFollowupAnswer"] = continued.0
            report["cachedPerformance"] = await model.brain.lastPerformance
            guard continued.0.contains("518") else { throw VoiceError("Cached conversation did not retain its tool result.") }
            let cancelStart = Date()
            let long = Task { try await model.brain.respond(prompt: "Tell me a very long story about the ocean.", history: [], webEnabled: false, onToken: { _ in }, onTool: { _ in }) }
            try await Task.sleep(for: .milliseconds(500)); long.cancel()
            _ = await long.result
            report["cancellationSeconds"] = Date().timeIntervalSince(cancelStart) - 0.5
            if ProcessInfo.processInfo.arguments.contains("--audio-test") {
                try await checkAudio(model: model, wav: wav, report: &report)
            }
            report["passed"] = true
            model.selfTestStatus = "Local LLM, tool calling, Kokoro, Parakeet and cancellation checks passed."
            model.status = "Ready when you are"
        } catch { report["passed"] = false; report["error"] = String(describing: error); model.error = "Integration check: \(error.localizedDescription)" }
        model.selfTestReport = String(data: (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data(), encoding: .utf8) ?? ""
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
        model.selfTestStatus = report["passed"] as? Bool == true ? "Integration checks passed" : "Integration check failed"
    }
    private static func checkAudio(model: CallModel, wav: URL, report: inout [String: Any]) async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw VoiceError("Microphone permission is needed for the audio check.") }
        let stream = try model.audio.start()
        let captured = AudioCheckCollector()
        let capture = Task {
            for await packet in stream { await captured.received(frames: Int(packet.buffer.frameLength)) }
        }
        defer { model.audio.stop(); capture.cancel() }
        let output = try await model.tts.synthesizeDetailed(text: "This is a playback interruption test. The audio should stop when speech is detected.", voice: "af_heart")
        try model.audio.enqueue(samples: output.samples + output.samples, text: "Test playback")
        try await Task.sleep(for: .milliseconds(300))
        guard model.audio.pendingBuffers > 0 else { throw VoiceError("Playback ended before the interruption check.") }
        await model.speech.reset()
        let input = try AudioConverter().resampleAudioFile(wav)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        for offset in stride(from: 0, to: min(input.count, 16000), by: 512) {
            let chunk = Array(input[offset..<min(input.count, offset + 512)])
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.count))!
            pcm.frameLength = AVAudioFrameCount(chunk.count)
            chunk.withUnsafeBufferPointer { pcm.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
            try await model.speech.feed(CapturedAudio(buffer: pcm), muted: false, pause: 0.9,
                onLevel: { _ in }, onStart: {
                    let elapsed = await MainActor.run {
                        let start = Date(); model.audio.interrupt()
                        return Date().timeIntervalSince(start)
                    }
                    await captured.interrupted(seconds: elapsed)
                }, onPartial: { _ in }, onFinal: { _ in })
            if await captured.didInterrupt { break }
        }
        try await Task.sleep(for: .milliseconds(300))
        let result = await captured.result()
        report["microphoneFramesReceived"] = result.0
        report["vadTriggeredPlaybackStopSeconds"] = result.1
        report["audioTestMethod"] = "Live microphone capture and speaker playback; synthetic speech fed into the live VAD triggers playback cancellation."
        guard result.0 > 0, result.1 >= 0, result.1 < 0.2, model.audio.pendingBuffers == 0 else { throw VoiceError("Live audio/interruption verification failed.") }
        await model.speech.reset()
    }
}
actor AudioCheckCollector {
    private var frames = 0
    private var stopSeconds = -1.0
    var didInterrupt: Bool { stopSeconds >= 0 }
    func received(frames: Int) { self.frames += frames }
    func interrupted(seconds: Double) { stopSeconds = seconds }
    func result() -> (Int, Double) { (frames, stopSeconds) }
}
actor CheckCollector {
    private var text = ""; private var tools: [String] = []
    func token(_ value: String) { text += value }
    func tool(_ value: String) { tools.append(value) }
    func result() -> (String, [String]) { (text, tools) }
}

actor LiveCheckCollector {
    private var starts = 0
    private var partials = 0
    private var finals: [String] = []
    func started() { starts += 1 }
    func partial(_ text: String) { partials += 1 }
    func final(_ text: String) { finals.append(text) }
    func result() -> (Int, Int, [String]) { (starts, partials, finals) }
}
