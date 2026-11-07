# Local Voice

A native SwiftUI Mac app for an interruptible, on-device voice conversation.

## Run

Open `realtime-voice-llm-local.xcodeproj` in Xcode and run the app target on **My Mac**. Use a Release build for responsive MLX inference. Xcode requires the Metal Toolchain component (install with `xcodebuild -downloadComponent MetalToolchain` if it is missing). Xcode may ask you to trust Apple's MLX `CudaBuild` package plugin (it is inactive on macOS).

The first launch downloads Qwen3.5-4B (4-bit), Parakeet Realtime EOU 120M, Silero VAD and Kokoro-82M Core ML assets. Allow several minutes for downloads and Core ML compilation. The setup screen shows the current stage; failed setup can be retried. Downloads are cached in the app's sandbox Application Support/LocalVoice/Models directory. The native Core ML Kokoro assets are separate from an existing Python/MLX installation.

Click **Start call** and grant microphone access. Speak English, pause to finish a turn, and speak over the AI to interrupt. The microphone remains active during playback. Escape or the stop button also interrupts. Use macOS Sound settings to choose the input/output device; restart a call after changing devices.

## Features

- Native GPU LLM inference, with thinking disabled and bounded conversation context. Completed turns reuse their KV cache; interruptions and web-permission changes rebuild it from the actual conversation.
- Streaming English recognition with live partial transcripts.
- Silero speech detection plus end-of-utterance and configurable silence handling.
- Kokoro speech generated phrase by phrase while the LLM continues producing text.
- AVAudioEngine voice-processing echo cancellation for simultaneous listening/playback.
- Immediate playback stop, queue invalidation and cancellation of old model tasks on interruption.
- Interrupted history uses played text plus an estimate of the partially played phrase, rather than the entire unspoken generation.
- Four selectable voices, speaking speed, mute, typed input, copy transcript and clear conversation.
- Local arithmetic and date/time tools; optional DuckDuckGo HTML search and public HTTPS page reading.
- Read-only tool allowlist, strict arithmetic parser, bounded tool loops, network timeouts and response limits.

All model inference stays in the app. Web search sends the query to DuckDuckGo and reading a result contacts that site. Disable **Web search** for offline conversations once model assets are cached. Search may be blocked by the provider; the app reports failure rather than fabricating results. No API key, Ollama, external server or Python runtime is needed.

Microphone audio is processed in memory, not saved. Transcripts remain in memory until cleared or the app quits. The copy button writes text to the clipboard only when requested.

## Verification

`LocalVoiceTests` covers text chunk boundaries, arithmetic, URL restrictions, tool availability and limits, and interruption state. Launch with `--self-test` for a real-model check: Kokoro generates a known sentence, Parakeet transcribes it, Qwen calls the calculator and cancellation is exercised. The report and generated test audio are written to Application Support/LocalVoice, inside the app sandbox, and the report appears in Call settings. Add `--audio-test` alongside `--self-test` to verify live microphone capture and speaker playback, then inject synthetic speech into the VAD to verify that it cancels queued playback. This hardware check plays a brief test phrase and requires microphone access.

Real speaker/microphone behaviour depends on device routing, room acoustics, distance and volume. Validate using the MacBook's speakers and your own voice; adjust the pause setting if turns finish too quickly.

## Structure

- `CallModel.swift`: call lifecycle, cancellation, transcript and speech queue.
- `VoiceAudio.swift`: voice-processing audio I/O and streaming STT/VAD.
- `LocalModels.swift`: model download/loading, tokenizer adapter and local LLM.
- `LocalTools.swift`: validated read-only tool dispatch.
- `ContentView.swift`: call controls and live transcript.
- `IntegrationCheck.swift`: opt-in real-model checks.

Dependencies are pinned by the Xcode package lockfile. Model receipts verify expected file sizes; Kokoro Core ML assets use the upstream pinned checksummed manifest. Qwen revision is resolved on first download and kept locally until its model folder is removed.

## Verified on this Mac

Release build and 9 unit tests pass on the M3 MacBook Air. The real-model check verifies streamed STT, Kokoro synthesis, calculator tool calling, cached follow-up context and cancellation. A live call successfully played responses with echo cancellation, performed DuckDuckGo search, and stopped playback using the interrupt control. Observed time to first audio was 3.4 seconds for a new greeting and 1.2 seconds for a cached follow-up. These are individual measurements, not guarantees; tools and longer context add latency. The hardware integration check received 81,600 microphone frames and stopped queued playback in 0.0039 seconds after the synthetic VAD speech callback. This measures the stop operation, not total speech-detection latency. Human speech-over-playback behaviour still needs a real conversation in your room.

## Microphone troubleshooting

The call screen shows the active system microphone and a live input meter. If no signal arrives, it displays guidance instead of silently waiting. Call settings shows the input level and speech confidence, with a link to macOS Sound settings. The built-in microphone requires an open MacBook lid.

Speech detection buffers the 4096 samples required by FluidAudio's compiled Silero model (256 ms at 16 kHz). It uses a lower release threshold to keep quiet syllables within the same utterance. The regression check now streams quiet, 48 kHz speech through the actual converter, detector and recogniser.

The audio graph explicitly requests mono voice output from Apple's voice-processing unit. On this Mac, its reported aggregate hardware format contains seven channels, including echo-reference channels; treating that as a normal microphone stream caused silent downmixing. The microphone tap and speaker output now use the same mono client format. Audio callbacks copy sample data into owned buffers before asynchronous processing. Echo cancellation defaults on; the optional off mode is for headphones.

After the mono-format fix, the live call meter received nonzero built-in microphone audio with echo cancellation enabled. The format is derived from the input node output bus, then constrained to one client channel; the aggregate channel count is never passed to the microphone tap.
