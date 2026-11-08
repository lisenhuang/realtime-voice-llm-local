import Foundation
import Observation

struct SpeechPreparationConfig: Equatable, Sendable {
    let profile: String
    let model: String
    let effort: String?
    let web: Bool
    let search: WebSearchProvider
    let voice: String
    let speed: Float
}
enum DraftEvent: Sendable {
    case text(String), tool(String), citations([TranscriptCitation])
}
protocol SpeechDraftEngine: Sendable {
    func run(snapshot: String, onEvent: @escaping @Sendable (DraftEvent) async -> Void) async throws
    func cancel() async
}

// Exact words must match before an early draft is released. Ignore casing,
// whitespace and terminal punctuation only; keep numbers and negations intact.
enum SpeechSnapshot {
    static func key(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!?")))
            .lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
struct StablePhrasePolicy {
    private var samples: [(time: TimeInterval, text: String)] = []
    private var changedAt: TimeInterval = 0
    private var current = ""
    private var lastSent = ""
    private var lastSentAt = -Double.infinity
    private(set) var requests = 0
    mutating func update(_ text: String, at now: TimeInterval) {
        if text != current { current = text; changedAt = now }
        samples.append((now, text))
        samples.removeAll { $0.time < now - 2 }
    }
    mutating func candidate(at now: TimeInterval) -> String? {
        guard requests < 6, now - lastSentAt >= 10 else { return nil }
        var candidate = ""
        if now - changedAt >= 0.3 {
            candidate = current
        } else if let old = samples.last(where: { $0.time <= now - 0.8 }) {
            let a = old.text.split(whereSeparator: { $0.isWhitespace })
            let b = current.split(whereSeparator: { $0.isWhitespace })
            let prefix = zip(a, b).prefix { $0.0 == $0.1 }.map { String($0.0) }
            if prefix.count >= 10 { candidate = prefix.dropLast(2).joined(separator: " ") }
        }
        guard candidate.split(whereSeparator: { $0.isWhitespace }).count >= 4,
              !SpeechSnapshot.key(candidate).isEmpty, SpeechSnapshot.key(candidate) != lastSent else { return nil }
        lastSent = SpeechSnapshot.key(candidate); lastSentAt = now; requests += 1
        return candidate
    }
}

// Internal ASR segments are not conversational turns. A long uninterrupted
// utterance remains one user message while the recogniser is periodically reset.
struct SpeechTranscriptSegments {
    private(set) var committed = ""
    mutating func append(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { committed += (committed.isEmpty ? "" : " ") + text }
    }
    func combining(_ partial: String) -> String {
        let partial = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        return committed + (committed.isEmpty || partial.isEmpty ? "" : " ") + partial
    }
    mutating func finish(_ tail: String) -> String { let result = combining(tail); committed = ""; return result }
    static func turnEnded(eou: Bool, silence: Double, pause: Double) -> Bool {
        (eou && silence > min(0.5, pause)) || silence > pause
    }
}

@Observable @MainActor
final class SpeechPreparation {
    let config: SpeechPreparationConfig
    private let engine: any SpeechDraftEngine
    private let synthesise: @Sendable (String) async throws -> [Float]
    private var policy = StablePhrasePolicy()
    private var ticker: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var audioTask: Task<[Float], Error>?
    private var audioPhrase = ""
    private var firstPhrase = PhraseBuffer()
    private var spokenFilter = SpokenTextFilter()
    private var queued: String?
    private var snapshot = ""
    private var events: [DraftEvent] = []
    private var continuation: AsyncThrowingStream<DraftEvent, Error>.Continuation?
    private var revision = UUID()
    private var confirmed = false
    private var completed = false
    private var stopped = false
    private var failure: Error?
    private(set) var requests = 0
    private(set) var reused = false
    var status = "Listening"
    init(config: SpeechPreparationConfig, engine: any SpeechDraftEngine,
         synthesise: @escaping @Sendable (String) async throws -> [Float]) {
        self.config = config; self.engine = engine; self.synthesise = synthesise
    }
    func update(_ text: String) {
        guard !confirmed, !stopped else { return }
        policy.update(text, at: Date.timeIntervalSinceReferenceDate)
        if ticker == nil {
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled, let self, !self.confirmed, !self.stopped else { return }
                    if let text = self.policy.candidate(at: Date.timeIntervalSinceReferenceDate) { self.queue(text) }
                }
            }
        }
    }
    // Public inside the module so integration tests can exercise the same
    // preparation/confirmation lifecycle without recording the microphone.
    func queue(_ text: String) {
        guard !stopped, !confirmed, failure == nil else { return }
        queued = text
        if worker == nil { begin(text) }
    }
    private func begin(_ text: String) {
        queued = nil; snapshot = text; events = []; completed = false; failure = nil
        firstPhrase = PhraseBuffer(); spokenFilter = SpokenTextFilter()
        audioTask?.cancel(); audioTask = nil; audioPhrase = ""
        revision = UUID(); let current = revision
        requests += 1; status = confirmed ? "Finishing your reply" : "Preparing silently while you speak"
        worker = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.engine.run(snapshot: text) { [weak self] event in await self?.receive(event, revision: current) }
                try Task.checkCancellation()
                guard self.revision == current, !self.stopped else { return }
                self.completed = true; self.worker = nil
                if self.audioTask == nil { self.prepareAudio(self.firstPhrase.finish()) }
                if self.confirmed { self.continuation?.finish(); self.continuation = nil }
                else if let next = self.queued, SpeechSnapshot.key(next) != SpeechSnapshot.key(self.snapshot) { self.begin(next) }
                else { self.status = "Reply prepared; still listening" }
            } catch {
                guard self.revision == current, !self.stopped else { return }
                self.worker = nil; self.failure = error
                self.status = "Will use the normal response path"
                if self.confirmed { self.continuation?.finish(throwing: error); self.continuation = nil }
            }
        }
    }
    private func receive(_ event: DraftEvent, revision: UUID) {
        guard self.revision == revision, !stopped else { return }
        events.append(event)
        if case .text(let text) = event, audioTask == nil {
            if let phrase = firstPhrase.append(spokenFilter.append(text)).first { prepareAudio(phrase) }
        }
        if confirmed { continuation?.yield(event) }
    }
    private func prepareAudio(_ phrase: String) {
        guard !phrase.isEmpty, audioTask == nil else { return }
        audioPhrase = phrase
        let synthesise = self.synthesise
        audioTask = Task { try Task.checkCancellation(); return try await synthesise(phrase) }
    }
    func cachedAudio(for phrase: String) async -> [Float]? {
        guard confirmed, phrase == audioPhrase, let task = audioTask else { return nil }
        let current = revision
        let samples = try? await task.value
        guard !stopped, current == revision, !Task.isCancelled else { return nil }
        return samples
    }
    func reply(to final: String, onEvent: @escaping @Sendable (DraftEvent) async -> Void) async throws {
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        ticker?.cancel(); ticker = nil; queued = nil
        if let failure { throw failure }
        let matches = !snapshot.isEmpty && SpeechSnapshot.key(snapshot) == SpeechSnapshot.key(final)
        if !matches && worker != nil {
            // Never wait behind stale reasoning or web work at end of speech.
            // Closing this socket cancels it; the normal HTTP path handles the
            // final transcript without allowing stale tokens to escape.
            cancel()
            throw VoiceError("The transcript changed during preparation. Regenerating from the final transcript.")
        }
        let stream = AsyncThrowingStream<DraftEvent, Error>.makeStream()
        continuation = stream.continuation; confirmed = true; reused = matches
        if matches {
            for event in events { continuation?.yield(event) }
            if completed { continuation?.finish(); continuation = nil }
        } else { begin(final) }
        try await withTaskCancellationHandler {
            for try await event in stream.stream { try Task.checkCancellation(); await onEvent(event) }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }
    func cancel() {
        guard !stopped else { return }
        stopped = true; revision = UUID(); ticker?.cancel(); ticker = nil
        worker?.cancel(); worker = nil; audioTask?.cancel(); audioTask = nil
        continuation?.finish(throwing: CancellationError()); continuation = nil
        let engine = self.engine; Task { await engine.cancel() }
    }
}
