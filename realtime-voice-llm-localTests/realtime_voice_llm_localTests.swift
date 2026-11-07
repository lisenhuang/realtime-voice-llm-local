import Foundation
import AVFoundation
import Testing
@testable import realtime_voice_llm_local

struct LocalVoiceTests {
    @Test func microphonePacketOwnsEveryCapturedSample() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        input.frameLength = 1024
        for channel in 0..<2 {
            for index in 0..<1024 { input.floatChannelData![channel][index] = Float(index + channel) / 2048 }
        }
        let packet = try #require(CapturedAudio.copy(from: input))
        #expect(packet.buffer.frameLength == 1024)
        #expect(packet.sourcePeak == 0.5)
        #expect(packet.buffer.floatChannelData![0][500] == Float(500) / 2048)
        #expect(packet.buffer.floatChannelData![1][1023] == 0.5)
        input.floatChannelData![1][1023] = 0
        #expect(packet.buffer.floatChannelData![1][1023] == 0.5)
    }

    @Test func phraseChunksPreserveTextAcrossTokenBoundaries() {
        var buffer = PhraseBuffer()
        var phrases = buffer.append("This is a complete")
        phrases += buffer.append(" sentence. Here comes")
        phrases += buffer.append(" another one!")
        let final = buffer.finish()
        if !final.isEmpty { phrases.append(final) }
        #expect(phrases.joined(separator: " ") == "This is a complete sentence. Here comes another one!")
    }
    @Test func decimalDoesNotBecomeSentenceBoundary() {
        var buffer = PhraseBuffer()
        let phrases = buffer.append("The final amount is 123.45 dollars.")
        #expect(phrases == ["The final amount is 123.45 dollars."])
    }
    @Test func shortRepliesAreFlushed() {
        var buffer = PhraseBuffer()
        #expect(buffer.append("Yes.").isEmpty)
        #expect(buffer.finish() == "Yes.")
        #expect(buffer.finish().isEmpty)
    }
    @Test func calculatorRespectsPrecedenceAndRejectsCode() throws {
        #expect(try Arithmetic.evaluate("37 * 14") == 518)
        #expect(try Arithmetic.evaluate("-(3 + 4) * 2 + 0.5") == -13.5)
        #expect(throws: (any Error).self) { try Arithmetic.evaluate("1 / 0") }
        #expect(throws: (any Error).self) { try Arithmetic.evaluate("system('open')") }
        #expect(throws: (any Error).self) { try Arithmetic.evaluate("(2 + 1") }
    }
    @Test func pageReaderRejectsLocalAndCredentialURLs() {
        for value in ["http://example.com", "https://127.0.0.1", "https://192.168.1.1", "https://localhost", "https://machine.local", "https://user:password@example.com", "https://example.com:8080", "file:///etc/passwd"] {
            #expect(!LocalTools.isPublicURL(URL(string: value)!))
        }
        #expect(LocalTools.isPublicURL(URL(string: "https://example.com/article")!))
    }
    @Test func webToggleRemovesNetworkCapabilities() {
        let offline = LocalTools.specifications(web: false)
        let online = LocalTools.specifications(web: true)
        #expect(offline.count == 2)
        #expect(online.count == 5)
    }
    @Test func toolBudgetPreventsUnboundedLoops() async {
        let budget = ToolBudget()
        for _ in 0..<4 { #expect(await budget.take()) }
        #expect(await budget.take() == false)
    }
    @Test @MainActor func interruptionInvalidatesPendingReply() {
        let model = CallModel()
        model.active = true
        model.thinking = true
        model.interrupt()
        #expect(!model.thinking)
        #expect(!model.speaking)
        #expect(model.audio.pendingBuffers == 0)
        #expect(model.status == "Listening")
        model.endCall()
        #expect(!model.active)
    }
}
