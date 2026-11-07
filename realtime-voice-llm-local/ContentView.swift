import SwiftUI

private let mint = Color(red: 0.46, green: 0.88, blue: 0.73)
private let canvas = Color(red: 0.055, green: 0.07, blue: 0.08)

struct ContentView: View {
    @State private var model = CallModel()
    @State private var showSettings = false
    var body: some View {
        HStack(spacing: 0) {
            callPanel.frame(minWidth: 350, idealWidth: 395, maxWidth: 440)
            Rectangle().fill(.white.opacity(0.08)).frame(width: 1)
            conversation.frame(minWidth: 400, maxWidth: .infinity)
        }
        .background(canvas)
        .preferredColorScheme(.dark)
        .frame(minWidth: 820, minHeight: 640)
        .task {
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
            if ProcessInfo.processInfo.arguments.contains("--prepare-cache") {
                try? FileManager.default.createDirectory(at: LocalBrain.modelsDirectory, withIntermediateDirectories: true)
                return
            }
            await model.prepare()
            if ProcessInfo.processInfo.arguments.contains("--self-test"), model.ready { await IntegrationCheck.run(model: model) }
        }
        .onDisappear { model.endCall() }
        .onChange(of: model.echoCancellation) { Task { await model.changeEchoCancellation() } }
        .onChange(of: model.webEnabled) { if !model.webEnabled { model.interrupt() } }
        .sheet(isPresented: $showSettings) { settings }
        .alert("Using your ChatGPT plan", isPresented: Binding(get: { model.chatGPT.showWelcome }, set: { model.chatGPT.showWelcome = $0 })) {
            Button("Got it") { model.chatGPT.welcomeSeen() }
        } message: {
            Text("Local Voice can now use your ChatGPT plan. Conversation text goes to OpenAI; speech recognition and voice playback stay on your Mac. Manage allowances in ChatGPT Settings → Usage.")
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                    .help("Voice and call settings").accessibilityLabel("Call settings")
            }
        }
    }
    private var callPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "waveform").font(.system(size: 20, weight: .semibold)).foregroundStyle(mint)
                Text("Local Voice").font(.system(size: 21, weight: .semibold))
                Spacer()
                Circle().fill(model.ready ? mint : .orange).frame(width: 7, height: 7)
            }
            .padding(.bottom, 12)
            Text("A conversation, on your Mac.").font(.system(size: 13)).foregroundStyle(.white.opacity(0.48))
            Spacer(minLength: 28)
            VStack(spacing: 26) {
                VoiceOrb(active: model.active, speaking: model.speaking, level: model.level, thinking: model.thinking)
                    .frame(width: 220, height: 220)
                VStack(spacing: 10) {
                    Text(model.status).font(.system(size: 25, weight: .medium, design: .rounded))
                        .contentTransition(.numericText())
                    Text(model.active ? (model.muted ? "Your microphone is off" : "Speak naturally. Interrupt anytime.") : "Your voice stays on this device.")
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.48))
                }
                if model.active {
                    VStack(spacing: 6) {
                        ProgressView(value: Double(model.muted ? 0 : model.level)).tint(mint)
                            .frame(width: 180).accessibilityLabel("Microphone input level")
                        Text(model.microphoneName).font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(model.muted ? "Microphone muted" : model.microphoneFeedback)
                            .font(.system(size: 11)).foregroundStyle(model.microphoneDB < -100 ? .orange : mint)
                            .multilineTextAlignment(.center)
                    }
                }
                if model.preparing {
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text(model.setupStatus).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Text("First setup downloads the models once.").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }.frame(height: 90)
                } else {
                    HStack(spacing: 12) {
                        if model.active {
                            Button { model.toggleMute() } label: { Image(systemName: model.muted ? "mic.slash.fill" : "mic.fill").frame(width: 44, height: 44) }
                                .buttonStyle(.plain).background(.white.opacity(0.08), in: Circle()).help(model.muted ? "Unmute" : "Mute")
                                .accessibilityLabel(model.muted ? "Unmute microphone" : "Mute microphone")
                        }
                        Button {
                            if model.active { model.endCall() } else { Task { await model.startCall() } }
                        } label: {
                            Label(model.active ? "End call" : "Start call", systemImage: model.active ? "phone.down.fill" : "waveform")
                                .font(.system(size: 15, weight: .semibold)).frame(width: 150, height: 46)
                                .foregroundStyle(model.active ? Color.white : canvas)
                                .background(model.active ? Color.red.opacity(0.7) : mint, in: Capsule())
                        }.buttonStyle(.plain).disabled(!model.canStart || model.checking).accessibilityIdentifier("startCall")
                        if model.active {
                            Button { model.interrupt() } label: { Image(systemName: "stop.fill").frame(width: 44, height: 44) }
                                .buttonStyle(.plain).background(.white.opacity(0.08), in: Circle()).help("Stop AI speech (Escape)")
                                .keyboardShortcut(.escape, modifiers: []).accessibilityLabel("Interrupt AI")
                        }
                    }.frame(height: 90)
                }
            }.frame(maxWidth: .infinity)
            Spacer(minLength: 24)
            if model.provider == .local && !model.ready && !model.preparing {
                Button("Use a downloaded model…") { Task { await model.importModel() } }
                    .font(.caption).tint(mint).padding(.bottom, 12)
            }
            if let error = model.error {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled)
                    if !model.ready && !model.preparing { Button("Retry setup") { Task { await model.prepare() } }.tint(mint) }
                    if error.contains("microphone access") {
                        Button("Open microphone settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!) }
                    }
                }.padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12)).padding(.bottom, 15)
            }
            VStack(spacing: 12) {
                Picker("AI model", selection: Binding(get: { model.provider }, set: { selection in Task { await model.changeProvider(selection) } })) {
                    Text("Local Qwen").tag(ModelProvider.local)
                    Text("ChatGPT").tag(ModelProvider.chatGPT)
                }.pickerStyle(.segmented).disabled(model.preparing || model.chatGPT.busy)
                HStack {
                    Label(model.provider == .local ? "Qwen3.5 · 4B" : model.chatGPT.modelName,
                          systemImage: model.provider == .local ? "lock.shield" : "cloud").foregroundStyle(mint).lineLimit(1)
                    Spacer()
                    if model.provider == .chatGPT {
                        Button(model.chatGPT.connected ? "Account & model" : "Connect account") { showSettings = true }
                    }
                }.font(.system(size: 11))
                if model.provider == .chatGPT && model.chatGPT.connected {
                    HStack {
                        Text("Using ChatGPT plan")
                        Spacer()
                        Link("Manage usage", destination: URL(string: "https://chatgpt.com/settings/usage")!)
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Web search").font(.system(size: 12))
                    Spacer()
                    Toggle("Web search", isOn: $model.webEnabled).labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(mint)
                }
                Text(model.provider == .chatGPT ? "Text is sent to OpenAI. Speech stays on your Mac." : (model.webEnabled ? "Only searches, weather lookups and page requests go online." : "Offline conversation. No web requests during calls."))
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(17).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        }.padding(28)
    }
    private var conversation: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Conversation").font(.system(size: 16, weight: .semibold))
                    HStack(spacing: 6) {
                        if let date = model.startedAt { Text(date, style: .timer).monospacedDigit() }
                        else { Text("Live transcript") }
                        if let latency = model.responseTime { Text("· \(latency, specifier: "%.1f")s response") }
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.copyTranscript() } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).help("Copy transcript").accessibilityLabel("Copy transcript")
                Button { model.newConversation() } label: { Image(systemName: "square.and.pencil") }.buttonStyle(.plain).padding(.leading, 12).help("New conversation").accessibilityLabel("New conversation")
            }.padding(26)
            Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if model.transcript.isEmpty && model.partial.isEmpty {
                            VStack(alignment: .leading, spacing: 15) {
                                Image(systemName: "text.bubble").font(.system(size: 26)).foregroundStyle(mint.opacity(0.6))
                                Text("Room to think out loud.").font(.system(size: 22, weight: .medium, design: .rounded))
                                Text("Start a call, then ask a question, explore an idea, or just talk. Your words and the AI’s replies appear here.")
                                    .font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(5)
                                HStack(spacing: 7) { Image(systemName: "arrow.turn.down.right"); Text("Try “Help me plan my weekend.”") }
                                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.4)).padding(.top, 7)
                            }.padding(.top, 65).padding(.horizontal, 10)
                        }
                        ForEach(model.transcript) { line in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(line.role == "user" ? "YOU" : "LOCAL VOICE")
                                        .font(.system(size: 10, weight: .bold)).tracking(1.3).foregroundStyle(line.role == "user" ? .white.opacity(0.4) : mint)
                                    if line.interrupted { Text("Interrupted").font(.system(size: 10)).foregroundStyle(.secondary) }
                                }
                                if line.text.isEmpty { Text("…").foregroundStyle(.secondary) }
                                else { Text(line.text).font(.system(size: 15)).lineSpacing(5).textSelection(.enabled).foregroundStyle(.white.opacity(line.interrupted ? 0.5 : 0.88)) }
                            }.frame(maxWidth: .infinity, alignment: .leading).id(line.id)
                        }
                        if !model.partial.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("YOU · LIVE").font(.system(size: 10, weight: .bold)).tracking(1.3).foregroundStyle(mint)
                                Text(model.partial).font(.system(size: 15)).foregroundStyle(.white.opacity(0.6)).lineSpacing(5)
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(26)
                }
                .onChange(of: model.transcript.last?.text) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: model.partial) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            if let tool = model.tools.last {
                HStack(spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver").foregroundStyle(mint)
                    Text(tool).lineLimit(2).textSelection(.enabled)
                    Spacer()
                }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 26).padding(.bottom, 14)
            }
            HStack(spacing: 12) {
                TextField(model.active ? "Or type something…" : "Start a call to speak or type", text: $model.typedText)
                    .textFieldStyle(.plain).font(.system(size: 13)).onSubmit { model.sendTyped() }.disabled(!model.active)
                    .accessibilityIdentifier("messageInput")
                Button { model.sendTyped() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 24)).foregroundStyle(model.active ? mint : .gray) }
                    .buttonStyle(.plain).disabled(!model.active || model.typedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityLabel("Send typed message")
            }.padding(15).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12)).padding(22)
        }.background(.white.opacity(0.015))
    }
    private var settings: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 22) {
            HStack { Text("Call settings").font(.title2.bold()); Spacer(); Button("Done") { showSettings = false } }
            ChatGPTSettings(account: model.chatGPT)
            Divider()
            Picker("Voice", selection: $model.voice) {
                Text("Heart · American English").tag("af_heart")
                Text("Bella · American English").tag("af_bella")
                Text("Adam · American English").tag("am_adam")
                Text("Emma · British English").tag("bf_emma")
            }
            VStack(alignment: .leading) {
                Text("Speaking speed: \(model.speed, specifier: "%.1f")×")
                Slider(value: $model.speed, in: 0.8...1.3, step: 0.1)
            }
            VStack(alignment: .leading) {
                Text("Pause before replying: \(model.pause, specifier: "%.1f") seconds")
                Slider(value: $model.pause, in: 0.6...1.6, step: 0.1)
                Text("Increase this if you like more time to finish your thought.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Echo cancellation", isOn: $model.echoCancellation)
            Text("Keep on with speakers. Turn off only when using headphones. Changing this restarts the call.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Local speech: Parakeet 120M · Kokoro 82M").font(.callout)
            Text("English speech recognition. Audio is not recorded to disk. Conversation history is held in memory until you clear it or quit. Both models interpret possible transcription mistakes using the conversation context.").font(.caption).foregroundStyle(.secondary)
            Text("Uses the microphone and speakers selected in macOS Sound settings. The microphone stays active during playback.").font(.caption).foregroundStyle(.secondary)
            if model.active {
                Text("Input: \(model.microphoneFormat) · peak \(model.rawMicrophoneDB, specifier: "%.0f") dBFS\nMicrophone: \(model.microphoneDB, specifier: "%.0f") dBFS · speech confidence: \(model.speechProbability * 100, specifier: "%.0f")%")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Button("Open Sound settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!) }
            if let test = model.selfTestStatus { Text(test).font(.caption).foregroundStyle(mint) }
            if !model.selfTestReport.isEmpty {
                ScrollView { Text(model.selfTestReport).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 160)
            }
        }.padding(28)
        }.frame(width: 540, height: 740).tint(mint)
    }
}

private struct VoiceOrb: View {
    let active: Bool
    let speaking: Bool
    let level: Float
    let thinking: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let energy = speaking ? 0.25 + 0.15 * sin(t * 4) : Double(level)
            ZStack {
                Circle().fill(mint.opacity(active ? 0.08 : 0.025)).blur(radius: 22).scaleEffect(1.2)
                Circle().stroke(mint.opacity(0.08), lineWidth: 1).padding(5)
                Circle().stroke(mint.opacity(0.12), lineWidth: 1).padding(25)
                Circle().fill(RadialGradient(colors: [mint.opacity(active ? 0.35 : 0.12), Color(red: 0.08, green: 0.2, blue: 0.19), canvas], center: .init(x: 0.35, y: 0.25), startRadius: 4, endRadius: 170))
                    .padding(36).overlay(Circle().stroke(mint.opacity(0.25), lineWidth: 1).padding(36))
                    .scaleEffect(1 + energy * 0.10)
                HStack(spacing: 5) {
                    ForEach(0..<9) { i in
                        let wave = abs(sin(t * (speaking ? 5 : 2) + Double(i) * 0.65))
                        Capsule().fill(mint.opacity(active ? 0.9 : 0.4))
                            .frame(width: 4, height: active ? 8 + wave * (thinking ? 18 : 12 + energy * 65) : 9 + Double(4 - abs(i - 4)) * 5)
                    }
                }
            }
        }.accessibilityLabel(active ? "Voice activity" : "Ready to talk")
    }
}
