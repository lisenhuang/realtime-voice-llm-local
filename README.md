# Local Voice

A native SwiftUI Mac app for an interruptible voice conversation with local speech and a choice of Local Qwen or ChatGPT text models.

## Run

Open `realtime-voice-llm-local.xcodeproj` in Xcode and run the app target on **My Mac**. Use a Release build for responsive MLX inference. Xcode requires the Metal Toolchain component (install with `xcodebuild -downloadComponent MetalToolchain` if it is missing). Xcode may ask you to trust Apple's MLX `CudaBuild` package plugin (it is inactive on macOS).

The first launch downloads Qwen3.5-4B (4-bit), Parakeet Realtime EOU 120M, Silero VAD and Kokoro-82M Core ML assets. Allow several minutes for downloads and Core ML compilation. The setup screen shows the current stage; failed setup can be retried. Downloads are cached in the app's sandbox Application Support/LocalVoice/Models directory. The native Core ML Kokoro assets are separate from an existing Python/MLX installation.

Click **Start call** and grant microphone access. Speak English, pause to finish a turn, and speak over the AI to interrupt. The microphone remains active during playback. Escape or the stop button also interrupts. Use macOS Sound settings to choose the input/output device; restart a call after changing devices.

## ChatGPT option

Choose **ChatGPT** on the call screen, open **Connect account**, then click **Continue with ChatGPT**. Complete sign-in and plan-usage consent in your browser. The app retrieves the models available to that account; choose a text model in Call settings, close settings, then start a call. Local Qwen remains available. Changing provider, account or model ends the call and clears its in-memory conversation.

This uses the official [Sign in with ChatGPT flow for locally hosted apps](https://developers.openai.com/siwc/token-sharing-open-source), public Responses API and your eligible ChatGPT plan. Eligibility, workspace permissions and plan/app allowances apply. Manage limits and access at [ChatGPT Settings → Usage](https://chatgpt.com/settings/usage). The app never reads Codex credentials and does not require an API key. General commercial distribution is outside this local prototype's scope and may require separate OpenAI onboarding.

OAuth uses system-browser login, a temporary listener bound only to `127.0.0.1`, PKCE S256, state and nonce validation, RS256 ID-token signature validation, and Keychain credential storage. Each account registration retains its own issued client ID and verified identity. Refreshes are serialized, rotating tokens are saved together, and sign-out attempts revocation before clearing local tokens. Saved account/client mappings and this installation's opaque host ID remain for reauthorization. No tokens are written to logs or the repository.

In ChatGPT mode, conversation text and tool results go to OpenAI. Speech recognition, voice activity detection, Kokoro and microphone audio remain local. Streaming cloud requests and queued speech are cancelled when you interrupt. Search and arithmetic tools still execute on the Mac. No shell or file-access tools are exposed.

**Reasoning level** in Call settings lists the selected model's supported public API efforts. GPT-6-Luna includes None to disable reasoning, even when the account catalog omits it; this exact-model supplement follows the [official model documentation](https://developers.openai.com/api/docs/models/gpt-6-luna). Choose Low for lighter reasoning, or a higher level when useful. None explicitly sends `reasoning.effort: "none"`; Model default leaves the effort parameter unset. These are separate choices. Choices are saved separately for each account and model and apply to the next reply, including every tool pass, without clearing the conversation. Unsupported or removed choices fall back to Model default.

**Web search provider** offers App tools or the model's built-in OpenAI web search. Click **Test model web search** (or **Test all models**) to run a short, forced web search with the signed-in account and selected reasoning effort. An actual completed `web_search_call` in a successfully completed response is required to verify support; a model's claim is insufficient. All-model checks use the current effort when supported, otherwise the model default. Results show full request duration, date, model and effort. Tests consume ChatGPT allowance and end any active call. A successful result enables model search for that exact account/model/effort for seven days. Untested, failed or expired combinations use app tools. The Web search toggle disables network search tools for either provider. Selection applies from the next reply.

Model search runs at OpenAI; app search and weather tools run on this Mac. Hosted source annotations appear as clickable citations and links in the transcript; citation control tokens are excluded from Kokoro speech. Tokens stay inside the app's Keychain-backed account flow during capability testing.

In App tools mode, weather questions use a dedicated Open-Meteo tool to resolve the requested location and retrieve current modelled conditions plus seven daily forecasts. Returned data includes local dates, timezone, units and source attribution. Missing values are not converted to zero. It follows the Web search permission toggle. The free Open-Meteo endpoint is for this personal, non-commercial prototype; commercial distribution needs an appropriate plan. General search and page-reading remain available, with instructions to try another relevant source when the first one fails.

Both providers receive instructions to interpret speech transcripts using conversation context, quietly resolve obvious misheard words, and ask a brief clarification if the meaning remains uncertain. They do not critique pronunciation unless asked.

## Features

- Native GPU LLM inference, with thinking disabled and bounded conversation context. Completed turns reuse their KV cache; interruptions and web-permission changes rebuild it from the actual conversation.
- Streaming English recognition with live partial transcripts.
- Silero speech detection plus end-of-utterance and configurable silence handling.
- Kokoro speech generated phrase by phrase while the LLM continues producing text.
- AVAudioEngine voice-processing echo cancellation for simultaneous listening/playback.
- Immediate playback stop, queue invalidation and cancellation of old model tasks on interruption.
- Interrupted history uses played text plus an estimate of the partially played phrase, rather than the entire unspoken generation.
- Four selectable voices, speaking speed, mute, typed input, copy transcript and clear conversation.
- Local arithmetic and date/time tools; optional Open-Meteo weather, DuckDuckGo HTML search and public HTTPS page reading.
- Read-only tool allowlist, strict arithmetic parser, bounded tool loops, network timeouts and response limits.

In Local Qwen mode, all model inference stays in the app. Web search sends the query to DuckDuckGo and reading a result contacts that site. Choose **Local Qwen** and disable **Web search** for offline conversations once model assets are cached. Search may be blocked by the provider; the app reports failure rather than fabricating results. No API key, Ollama, external server or Python runtime is needed.

Microphone audio is processed in memory, not saved. Transcripts remain in memory until cleared or the app quits. The copy button writes text to the clipboard only when requested.

## Verification

`ChatGPTTests` verifies PKCE, callback state/client binding, signed identity tokens, model catalogs, SSE framing, plan-compatible tools, and real loopback callbacks. Mocked streaming tests cover completion, failures after partial text, interrupted connections and network cancellation, without using an account or spending plan usage. `LocalVoiceTests` covers text chunk boundaries, arithmetic, URL restrictions, tool availability and limits, and interruption state. Launch with `--self-test` for a real-model check: Kokoro generates a known sentence, Parakeet transcribes it, Qwen calls the calculator and cancellation is exercised. The report and generated test audio are written to Application Support/LocalVoice, inside the app sandbox, and the report appears in Call settings. Add `--audio-test` alongside `--self-test` to verify live microphone capture and speaker playback, then inject synthetic speech into the VAD to verify that it cancels queued playback. This hardware check plays a brief test phrase and requires microphone access.

Real speaker/microphone behaviour depends on device routing, room acoustics, distance and volume. Validate using the MacBook's speakers and your own voice; adjust the pause setting if turns finish too quickly.

## Structure

- `CallModel.swift`: call lifecycle, cancellation, transcript and speech queue.
- `VoiceAudio.swift`: voice-processing audio I/O and streaming STT/VAD.
- `LocalModels.swift`: model download/loading, tokenizer adapter and local LLM.
- `LocalTools.swift`: validated read-only tool dispatch.
- `ChatGPTAccount.swift` and `ChatGPTSecurity.swift`: account lifecycle, Keychain, OAuth and identity validation.
- `ChatGPTBrain.swift`: cancellable Responses streaming and local tool loop.
- `ChatGPTSettings.swift`: account and model selection.
- `VoiceInstructions.swift`: shared voice and imperfect-transcription instructions.
- `ContentView.swift`: call controls and live transcript.
- `IntegrationCheck.swift`: opt-in real-model checks.

Dependencies are pinned by the Xcode package lockfile. Model receipts verify expected file sizes; Kokoro Core ML assets use the upstream pinned checksummed manifest. Qwen revision is resolved on first download and kept locally until its model folder is removed.

## Verified on this Mac

The original local implementation passed its Release build and 9 unit tests on the M3 MacBook Air. The real-model check verifies streamed STT, Kokoro synthesis, calculator tool calling, cached follow-up context and cancellation. A live call successfully played responses with echo cancellation, performed DuckDuckGo search, and stopped playback using the interrupt control. Observed time to first audio was 3.4 seconds for a new greeting and 1.2 seconds for a cached follow-up. These are individual measurements, not guarantees; tools and longer context add latency. The hardware integration check received 81,600 microphone frames and stopped queued playback in 0.0039 seconds after the synthetic VAD speech callback. This measures the stop operation, not total speech-detection latency. The user subsequently confirmed live conversation worked after the microphone fix. Cloud account login and live cloud responses require user sign-in; mocked tests do not establish account eligibility or live latency.

## Microphone troubleshooting

The call screen shows the active system microphone and a live input meter. If no signal arrives, it displays guidance instead of silently waiting. Call settings shows the input level and speech confidence, with a link to macOS Sound settings. The built-in microphone requires an open MacBook lid.

Speech detection buffers the 4096 samples required by FluidAudio's compiled Silero model (256 ms at 16 kHz). It uses a lower release threshold to keep quiet syllables within the same utterance. The regression check now streams quiet, 48 kHz speech through the actual converter, detector and recogniser.

The audio graph explicitly requests mono voice output from Apple's voice-processing unit. On this Mac, its reported aggregate hardware format contains seven channels, including echo-reference channels; treating that as a normal microphone stream caused silent downmixing. The microphone tap and speaker output now use the same mono client format. Audio callbacks copy sample data into owned buffers before asynchronous processing. Echo cancellation defaults on; the optional off mode is for headphones.

After the mono-format fix, the live call meter received nonzero built-in microphone audio with echo cancellation enabled. The format is derived from the input node output bus, then constrained to one client channel; the aggregate channel count is never passed to the microphone tap.

## ChatGPT web-search verification

On 8 November 2026, the signed-in GPT-6-Luna model with Low reasoning completed a native web-search probe with one completed search call and one source citation in 5.4 seconds. A subsequent native-search Auckland weather conversation reached first audio in 3.6 seconds and used the correct Auckland local date after adding current-time context. These are individual measurements, not latency guarantees. The app-tools weather route also returned a forecast successfully. The full automated suite passed 30 tests; the normal Release build passed. The all-model live benchmark was not run because automatic approval review required separate approval for the batch's plan usage.

The streaming reader retains completed output items even when the final response's output array is empty. Capability checks require a successfully completed response plus a completed search item or search-completed event. Citation control tokens are excluded from speech and interruption comparisons. Current time and timezone are included in both model prompts; source attribution is conditional on the data actually returned.

## Balanced preparation while speaking

Call settings includes **Prepare while I speak · Balanced**, enabled by default. It applies to ChatGPT voice calls; local Qwen and typed messages keep their existing response path. Stable partial transcripts can start silent drafts while the user continues speaking. The policy waits for stable words, spaces requests by at least ten seconds and allows at most six early requests per spoken turn. This can consume additional ChatGPT allowance and perform read-only web lookups before the final transcript. Microphone audio and speech synthesis remain local.

Each spoken turn uses a cancellable Responses WebSocket. Completed drafts are linked using connection-local `previous_response_id` with `store:false`; later transcript snapshots replace earlier snapshots in the instructions. This is speculative preparation with serialized updates, not continuous input to a single reasoning operation. The app also synthesises the first phrase silently. It releases buffered text and audio only after the final transcript matches the draft's words, allowing only case, whitespace and terminal-punctuation differences. Changed numbers or negations require a new response. A changed final transcript can continue from a completed draft; if an old draft is still running, the app cancels its socket and uses the normal final-transcript HTTP path. Unsupported connections and early errors also fall back. Interruption, mute, ending the call and account changes cancel unconfirmed preparation.

The old forced 35-second end-of-turn is removed. Continuous speech is retained as one user message, with internal recogniser segments every 25 seconds. Silence/end-of-utterance detection still determines when to respond; the pause control remains available. Natural pauses and recognition errors can still affect turn boundaries. Preparation reduces waiting when reusable work is ready, but does not guarantee an immediate reply, especially after late corrections or web lookups.

`PreparationTests` checks stability limits, matching, negations/numbers, segment joining, silent audio reuse, updated intent and cancellation. Launch with `--balanced-test` for an opt-in signed-in **GPT-6-Luna only** check: three short model responses verify draft reuse and corrected intent over a persistent connection, using real Kokoro synthesis. Results appear in Call settings. This diagnostic uses synthetic transcript confirmation and does not measure microphone-to-speaker latency or prove a real 60-second voice turn.

On 8 November 2026, the Release build and 38 automated tests passed. The signed-in GPT-6-Luna / Low diagnostic passed: the initial silent draft completed in 3.256 seconds; after synthetic confirmation, matching text was available in 0.00034 seconds and 69,600 cached Kokoro audio samples in 0.076 seconds. Changing the capital question from Australia to New Zealand returned Wellington in 1.222 seconds using the same connection's completed-response continuation. These are single-run component measurements, not end-to-end live voice latency guarantees.

On 8 November 2026, the GPT-6-Luna None reasoning update passed the Release build and all 40 automated tests. A live request using the app’s signed-in ChatGPT account and explicit `reasoning.effort: "none"` completed a native web search with one search call and one citation in 6.0 seconds. This confirms support for this account; it is a single full web-search request timing, not a comparison of conversational latency.
