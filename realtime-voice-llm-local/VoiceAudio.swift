import AVFoundation
import Foundation
import FluidAudio
import CoreML
import CoreAudio

struct CapturedAudio: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var sourcePeak: Float = 0
    static func copy(from source: AVAudioPCMBuffer) -> CapturedAudio? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength),
              let input = source.floatChannelData, let output = copy.floatChannelData else { return nil }
        copy.frameLength = source.frameLength
        let channels = source.format.isInterleaved ? 1 : Int(source.format.channelCount)
        let count = Int(source.frameLength) * (source.format.isInterleaved ? Int(source.format.channelCount) : 1)
        var peak: Float = 0
        for channel in 0..<channels {
            output[channel].update(from: input[channel], count: count)
            for index in 0..<count { peak = max(peak, abs(input[channel][index])) }
        }
        return CapturedAudio(buffer: copy, sourcePeak: peak)
    }
}

@MainActor
final class CallAudio {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var continuation: AsyncStream<CapturedAudio>.Continuation?
    private var playbackGeneration = UUID()
    private(set) var pendingBuffers = 0
    private var queuedText: [(text: String, duration: Double)] = []
    private var phraseStarted = Date()
    var onPhrasePlayed: ((String) -> Void)?
    var onOutputChanged: ((Bool) -> Void)?
    var onDeviceChanged: (() -> Void)?
    private var engineGeneration = UUID()
    private var observer: NSObjectProtocol?
    private(set) var inputDescription = "System microphone"
    static func defaultInputName() -> String {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return "System microphone" }
        var name: CFString = "System microphone" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        address.mSelector = kAudioObjectPropertyName
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return "System microphone" }
        return name as String
    }

    func start(voiceProcessing: Bool = true) throws -> AsyncStream<CapturedAudio> {
        stop()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let input = engine.inputNode
        // Voice-processing I/O provides echo cancellation while the mic stays active.
        if voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
            input.isVoiceProcessingAGCEnabled = true
            input.isVoiceProcessingInputMuted = false
        }
        engine.attach(player)
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: format)
        let pair = AsyncStream<CapturedAudio>.makeStream(bufferingPolicy: .bufferingNewest(64))
        self.continuation = pair.continuation
        let hardwareFormat = input.outputFormat(forBus: 0)
        inputDescription = Self.defaultInputName()
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else { throw VoiceError("No microphone is available. Connect a microphone and try again.") }
        // VPIO exposes an aggregate hardware format including reference
        // channels. Request its mono voice output instead of capturing the
        // aggregate and letting a surround downmixer select silent channels.
        let inputFormat = AVAudioFormat(standardFormatWithSampleRate: hardwareFormat.sampleRate, channels: 1)!
        // VPIO requires the same client sample rate in both directions. Keep
        // Kokoro at 24 kHz on its player bus and let the mixer resample it.
        let duplexFormat = AVAudioFormat(standardFormatWithSampleRate: inputFormat.sampleRate, channels: 1)!
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: duplexFormat)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            if let packet = CapturedAudio.copy(from: buffer) { pair.continuation.yield(packet) }
        }
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); pair.continuation.finish(); throw error }
        player.play()
        self.engine = engine; self.player = player
        let generation = engineGeneration
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.engineGeneration == generation else { return }
                self.onDeviceChanged?()
            }
        }
        return pair.stream
    }
    func enqueue(samples: [Float], text: String) throws {
        guard let engine, engine.isRunning, let player else { throw VoiceError("The audio output stopped. Restart the call.") }
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        guard !samples.isEmpty, samples.allSatisfy(\.isFinite),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { throw VoiceError("The voice model returned invalid audio.") }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { ptr in buffer.floatChannelData![0].update(from: ptr.baseAddress!, count: ptr.count) }
        let ticket = playbackGeneration
        if pendingBuffers == 0 { phraseStarted = Date() }
        pendingBuffers += 1
        queuedText.append((text, Double(samples.count) / 24_000))
        onOutputChanged?(true)
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playbackGeneration == ticket else { return }
                self.pendingBuffers = max(0, self.pendingBuffers - 1)
                if !self.queuedText.isEmpty { self.queuedText.removeFirst() }
                self.phraseStarted = Date()
                self.onPhrasePlayed?(text)
                if self.pendingBuffers == 0 { self.onOutputChanged?(false) }
            }
        }
        if !player.isPlaying { player.play() }
    }
    @discardableResult func interrupt() -> String {
        var partlyHeard = ""
        if let current = queuedText.first {
            let fraction = min(1, max(0, Date().timeIntervalSince(phraseStarted) / max(0.01, current.duration)))
            let words = current.text.split(separator: " ")
            partlyHeard = words.prefix(Int(Double(words.count) * fraction)).joined(separator: " ")
        }
        playbackGeneration = UUID()
        player?.stop()
        if engine?.isRunning == true { player?.play() }
        queuedText.removeAll(); pendingBuffers = 0
        onOutputChanged?(false)
        return partlyHeard
    }
    func stop() {
        engineGeneration = UUID()
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        interrupt()
        continuation?.finish(); continuation = nil
        if let engine { engine.inputNode.removeTap(onBus: 0); engine.stop() }
        engine = nil; player = nil
    }
}

// One consumer feeds this actor in order. No concurrent microphone inference jobs.
actor SpeechInput {
    private let asr: StreamingEouAsrManager
    private var vad: VadManager?
    private var vadState = VadStreamState.initial()
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    private var pending: [Float] = []
    private var preroll: [Float] = []
    private var utterance = false
    private var voicedFrames = 0
    private var silence = 0.0
    private var duration = 0.0
    private var previousPartial = ""
    private var wasMuted = false

    init() {
        let config = MLModelConfiguration(); config.computeUnits = .cpuAndNeuralEngine
        asr = StreamingEouAsrManager(configuration: config, chunkSize: .ms160, eouDebounceMs: 240)
    }
    func load(status: @escaping @Sendable (String) -> Void) async throws {
        status("Preparing Parakeet speech recognition…")
        try await asr.loadModels(to: LocalBrain.modelsDirectory)
        status("Preparing speech detection…")
        vad = try await VadManager(modelDirectory: LocalBrain.modelsDirectory)
    }
    func reset() async {
        await asr.reset()
        vadState = .initial(); pending = []; preroll = []; utterance = false
        voicedFrames = 0; silence = 0; duration = 0; previousPartial = ""; converter = nil
    }
    func feed(_ captured: CapturedAudio, muted: Bool, pause: Double,
              onLevel: @Sendable (Float) async -> Void,
              onDiagnostics: @Sendable (Float, Float) async -> Void = { _, _ in },
              onStart: @Sendable () async -> Void,
              onPartial: @Sendable (String) async -> Void,
              onFinal: @Sendable (String) async -> Void) async throws {
        guard let vad else { return }
        if muted { if !wasMuted { await reset() }; wasMuted = true; return }
        wasMuted = false
        let buffer = captured.buffer
        if converter == nil || converter!.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: targetFormat) }
        guard let converter,
              let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate + 64)) else { return }
        var provided = false; var error: NSError?
        converter.convert(to: output, error: &error) { _, state in
            if provided { state.pointee = .noDataNow; return nil }
            provided = true; state.pointee = .haveData; return buffer
        }
        if let error { throw error }
        guard let samples = output.floatChannelData?[0] else { return }
        pending.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
        // FluidAudio's compiled Silero model takes 4096 NEW samples, not
        // the 512 used by other Silero exports. Short input is padded by the
        // SDK, which distorts the waveform and suppresses real speech.
        let frameSize = VadManager.chunkSize
        let frameDuration = Double(frameSize) / 16000
        while pending.count >= frameSize {
            try Task.checkCancellation()
            let frame = Array(pending.prefix(frameSize)); pending.removeFirst(frameSize)
            let rms = sqrt(frame.reduce(Float(0)) { $0 + $1 * $1 } / Float(frameSize))
            await onLevel(min(1, sqrt(rms) * 4))
            let result = try await vad.processStreamingChunk(frame, state: vadState)
            vadState = result.state
            await onDiagnostics(rms, result.probability)
            let speech = result.probability >= (utterance ? 0.35 : 0.5) && rms > 0.0001
            voicedFrames = speech ? voicedFrames + 1 : 0
            if !utterance {
                preroll.append(contentsOf: frame)
                if preroll.count > frameSize * 2 { preroll.removeFirst(preroll.count - frameSize * 2) }
                if voicedFrames >= 1 {
                    utterance = true; silence = 0; duration = 0
                    await onStart()
                    try await recognise(preroll); preroll.removeAll()
                } else { continue }
            } else { try await recognise(frame) }
            duration += frameDuration
            silence = speech ? 0 : silence + frameDuration
            let partial = await asr.getPartialTranscript().trimmingCharacters(in: .whitespacesAndNewlines)
            if partial != previousPartial, !partial.isEmpty { previousPartial = partial; await onPartial(partial) }
            let ended = await asr.eouDetected
            if (ended && silence > min(0.5, pause)) || silence > pause || duration > 35 {
                let final = try await asr.finish().trimmingCharacters(in: .whitespacesAndNewlines)
                await asr.reset()
                utterance = false; voicedFrames = 0; previousPartial = ""; preroll = []
                if !final.isEmpty { await onFinal(final) }
            }
        }
    }
    private func recognise(_ samples: [Float]) async throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        _ = try await asr.process(audioBuffer: buffer)
    }
    // Uses exactly the live recogniser, with a known local WAV, for integration verification.
    func transcribeFile(_ url: URL) async throws -> String {
        await asr.reset()
        let samples = try AudioConverter().resampleAudioFile(url)
        for offset in stride(from: 0, to: samples.count, by: 1280) {
            try await recognise(Array(samples[offset..<min(samples.count, offset + 1280)]))
        }
        let result = try await asr.finish()
        await asr.reset()
        return result
    }
}
