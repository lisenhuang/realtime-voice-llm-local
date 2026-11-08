import Foundation
import FluidAudio

// Opt-in diagnostic: uses the app's signed-in account, never external credentials.
// No microphone input or playback. Reports simulated transcript-confirmation latency.
@MainActor enum BalancedIntegrationCheck {
    static func run(model: CallModel) async {
        model.checking = true
        defer { model.checking = false }
        var report: [String: Any] = ["method": "Synthetic transcript confirmation; real GPT-6-Luna and local Kokoro; no microphone or playback"]
        var drafts: [SpeechPreparation] = []
        defer { for draft in drafts { draft.cancel() } }
        do {
            guard model.chatGPT.canUse, model.chatGPT.modelID.lowercased().contains("gpt-6-luna") else { throw VoiceError("Select signed-in GPT-6-Luna before this diagnostic.") }
            let config = SpeechPreparationConfig(profile: model.chatGPT.selectedID, model: model.chatGPT.modelID, effort: model.chatGPT.reasoningEffort, web: false, search: .appTools, voice: model.voice, speed: Float(model.speed))
            report["model"] = config.model; report["reasoning"] = config.effort ?? "default"
            func make() -> SpeechPreparation {
                let draft = SpeechPreparation(config: config, engine: SpeechDraftSocket(config: config, history: [], account: model.chatGPT)) { phrase in
                    try await model.tts.synthesizeDetailed(text: phrase, voice: config.voice, speed: config.speed).samples
                }
                drafts.append(draft); return draft
            }
            func wait(_ draft: SpeechPreparation) async throws {
                for _ in 0..<600 {
                    if draft.status == "Reply prepared; still listening" { return }
                    if draft.status == "Will use the normal response path" { throw VoiceError("WebSocket preparation failed; normal HTTP fallback remains available.") }
                    try await Task.sleep(for: .milliseconds(100))
                }
                throw VoiceError("Preparation diagnostic timed out")
            }
            model.status = "Checking silent preparation"
            let draft = make(); let start = Date()
            let question = "What is the capital of Australia? Answer in one short sentence."
            draft.queue(question); try await wait(draft)
            report["draftSeconds"] = Date().timeIntervalSince(start)
            let collector = CheckCollector(); let confirmedAt = Date()
            try await draft.reply(to: question) { event in if case .text(let text) = event { await collector.token(text) } }
            let text = await collector.result().0
            report["matchingAnswer"] = text
            report["confirmationToTextSeconds"] = Date().timeIntervalSince(confirmedAt)
            var phraseBuffer = PhraseBuffer()
            let phrase = phraseBuffer.append(SpokenTextFilter.comparisonText(text)).first ?? phraseBuffer.finish()
            let audio = await draft.cachedAudio(for: phrase)
            report["confirmationToCachedAudioSeconds"] = Date().timeIntervalSince(confirmedAt)
            report["cachedAudioSamples"] = audio?.count ?? 0
            report["matchingRequests"] = draft.requests
            guard draft.reused, draft.requests == 1, text.lowercased().contains("canberra"), !(audio?.isEmpty ?? true) else { throw VoiceError("Matching draft/audio reuse check failed.") }
            model.status = "Checking corrections while speaking"
            let revised = make(); revised.queue(question); try await wait(revised)
            let correction = CheckCollector(); let revisionStart = Date()
            try await revised.reply(to: "What is the capital of New Zealand? Answer in one short sentence.") { event in if case .text(let text) = event { await correction.token(text) } }
            let updatedText = await correction.result().0
            report["correctedAnswer"] = updatedText; report["correctedSeconds"] = Date().timeIntervalSince(revisionStart)
            report["correctedRequests"] = revised.requests
            guard !revised.reused, revised.requests == 2, updatedText.lowercased().contains("wellington"), !updatedText.lowercased().contains("canberra") else { throw VoiceError("Revised intent did not replace the silent draft.") }
            report["passed"] = true
            model.status = "Ready when you are"
        } catch { report["passed"] = false; report["error"] = error.localizedDescription; model.error = "Preparation check: \(error.localizedDescription)" }
        model.selfTestStatus = report["passed"] as? Bool == true ? "Balanced preparation checks passed" : "Balanced preparation check failed"
        model.selfTestReport = String(decoding: (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data(), as: UTF8.self)
    }
}
