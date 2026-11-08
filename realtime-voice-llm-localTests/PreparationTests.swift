import Foundation
import Testing
@testable import realtime_voice_llm_local

private actor DraftStub: SpeechDraftEngine {
    var snapshots: [String] = []
    var cancelled = false
    let delay: Duration
    init(delay: Duration = .zero) { self.delay = delay }
    func run(snapshot: String, onEvent: @escaping @Sendable (DraftEvent) async -> Void) async throws {
        snapshots.append(snapshot)
        try await Task.sleep(for: delay)
        try Task.checkCancellation()
        await onEvent(.text("Answer for \(snapshot)."))
    }
    func cancel() { cancelled = true }
}
private actor DraftCollector {
    var text = ""
    func event(_ event: DraftEvent) { if case .text(let value) = event { text += value } }
}
@MainActor
struct PreparationTests {
    private let config = SpeechPreparationConfig(profile: "test", model: "test", effort: "low", web: false, search: .appTools, voice: "test", speed: 1)
    private func finished(_ draft: SpeechPreparation) async throws {
        for _ in 0..<200 {
            if draft.status == "Reply prepared; still listening" { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw VoiceError("Draft did not complete")
    }
    @Test func snapshotMatchPreservesChangedMeaning() {
        #expect(SpeechSnapshot.key(" Hello world! ") == SpeechSnapshot.key("hello world"))
        #expect(SpeechSnapshot.key("I want it") != SpeechSnapshot.key("I do not want it"))
        #expect(SpeechSnapshot.key("Set 15 minutes") != SpeechSnapshot.key("Set 50 minutes"))
        #expect(SpeechSnapshot.key("Is 1.5 correct?") != SpeechSnapshot.key("Is 15 correct?"))
    }
    @Test func stablePhrasesAreThrottledAndBounded() {
        var policy = StablePhrasePolicy()
        policy.update("please tell me something", at: 0)
        #expect(policy.candidate(at: 0.1) == nil)
        #expect(policy.candidate(at: 0.4) == "please tell me something")
        for i in 1...5 {
            policy.update("please tell me something number \(i)", at: Double(i * 11))
            #expect(policy.candidate(at: Double(i * 11) + 0.1) == nil)
            #expect(policy.candidate(at: Double(i * 11) + 0.4) != nil)
        }
        policy.update("please tell me something else", at: 80)
        #expect(policy.candidate(at: 81) == nil)
        #expect(policy.requests == 6)
    }
    @Test func continuingSpeechUsesOnlyStablePrefix() {
        var policy = StablePhrasePolicy()
        policy.update("one two three four five six seven eight nine ten eleven twelve", at: 0)
        policy.update("one two three four five six seven eight nine ten eleven thirteen more", at: 0.9)
        #expect(policy.candidate(at: 0.95) == "one two three four five six seven eight nine")
        policy.update("a completely different sentence now", at: 1)
        #expect(policy.candidate(at: 1.5) == nil)
    }
    @Test func recogniserSegmentsDoNotFinishLongTurn() {
        var segments = SpeechTranscriptSegments()
        for index in 0..<3 {
            segments.append("segment \(index)")
            #expect(!SpeechTranscriptSegments.turnEnded(eou: true, silence: 0, pause: 0.9))
        }
        #expect(segments.finish("final words") == "segment 0 segment 1 segment 2 final words")
        #expect(segments.committed.isEmpty)
        #expect(SpeechTranscriptSegments.turnEnded(eou: false, silence: 1, pause: 0.9))
    }
    @Test func matchingDraftStaysSilentUntilConfirmedAndReusesAudio() async throws {
        let engine = DraftStub(); let output = DraftCollector()
        let draft = SpeechPreparation(config: config, engine: engine, synthesise: { _ in [0.25, 0.5] })
        defer { draft.cancel() }
        draft.queue("hello there")
        try await finished(draft)
        #expect(await output.text.isEmpty)
        #expect(await draft.cachedAudio(for: "Answer for hello there.") == nil)
        try await draft.reply(to: "Hello there!") { await output.event($0) }
        #expect(await output.text == "Answer for hello there.")
        #expect(draft.reused && draft.requests == 1)
        #expect(await draft.cachedAudio(for: "Answer for hello there.") == [0.25, 0.5])
        #expect(await engine.snapshots == ["hello there"])
    }
    @Test func revisedFinalNeverReleasesOldDraft() async throws {
        let engine = DraftStub(); let output = DraftCollector()
        let draft = SpeechPreparation(config: config, engine: engine, synthesise: { _ in [] })
        defer { draft.cancel() }
        draft.queue("Australia")
        try await finished(draft)
        try await draft.reply(to: "New Zealand") { await output.event($0) }
        #expect(await output.text == "Answer for New Zealand.")
        #expect(!draft.reused && draft.requests == 2)
        #expect(await engine.snapshots == ["Australia", "New Zealand"])
    }
    @Test func revisedFinalCancelsBusyDraftWithoutWaiting() async throws {
        let engine = DraftStub(delay: .seconds(30)); let output = DraftCollector()
        let draft = SpeechPreparation(config: config, engine: engine, synthesise: { _ in [] })
        draft.queue("old question")
        do {
            try await draft.reply(to: "different question") { await output.event($0) }
            Issue.record("Expected final-transcript fallback")
        } catch { #expect(error is VoiceError) }
        #expect(await output.text.isEmpty)
        for _ in 0..<100 { if await engine.cancelled { break }; await Task.yield() }
        #expect(await engine.cancelled)
    }
    @Test func interruptionUnblocksConfirmedStream() async throws {
        let engine = DraftStub(delay: .seconds(30))
        let draft = SpeechPreparation(config: config, engine: engine, synthesise: { _ in [] })
        draft.queue("same question")
        let reply = Task { try await draft.reply(to: "same question") { _ in } }
        try await Task.sleep(for: .milliseconds(10))
        draft.cancel()
        do { try await reply.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
    }
}
