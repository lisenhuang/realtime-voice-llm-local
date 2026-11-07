import SwiftUI

struct ChatGPTSettings: View {
    @Bindable var account: ChatGPTAccount
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ChatGPT connection").font(.headline)
            Text("Speech recognition and Kokoro run on your Mac. In ChatGPT mode, conversation text and tool results are sent to OpenAI. Your microphone audio stays on this device.")
                .font(.caption).foregroundStyle(.secondary)
            if !account.profiles.isEmpty {
                Picker("Account", selection: Binding(get: { account.selectedID }, set: { account.choose($0) })) {
                    Text("Choose an account").tag("")
                    ForEach(account.profiles) { profile in
                        Text(profile.label + (profile.connected ? "" : " · signed out")).tag(profile.id)
                    }
                }.disabled(account.busy)
            }
            if account.busy {
                HStack { ProgressView().controlSize(.small); Text("Connecting…"); Spacer(); if account.canCancel { Button("Cancel") { account.cancelLogin() } } }
            } else {
                HStack {
                    Button("Continue with ChatGPT") { account.signIn() }.buttonStyle(.borderedProminent)
                    if !account.profiles.isEmpty { Button("Add account") { account.signIn(addAccount: true) } }
                }
            }
            if account.connected {
                Text("Using your ChatGPT plan").font(.subheadline.weight(.medium))
                if !account.models.isEmpty {
                    Picker("Text model", selection: Binding(get: { account.modelID }, set: { account.chooseModel($0) })) {
                        ForEach(account.models) { model in Text(model.name).tag(model.id) }
                    }.disabled(account.busy)
                    Picker("Reasoning level", selection: Binding(get: { account.reasoningChoice }, set: { account.chooseReasoning($0) })) {
                        Text("Model default").tag("default")
                        ForEach(account.selectedModel?.reasoningLevels ?? [], id: \.self) { effort in
                            Text(ChatGPTModel.effortLabel(effort)).tag(effort)
                        }
                    }.disabled(account.busy || (account.selectedModel?.reasoningLevels.isEmpty ?? true))
                    Text((account.selectedModel?.reasoningLevels.isEmpty ?? true)
                         ? "This model does not advertise adjustable reasoning levels. Using its default."
                         : "Lower levels usually reply faster. Higher levels spend more time thinking. Saved for this model and account; applies from your next reply.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Refresh models") { Task { await account.loadModels() } }.disabled(account.busy)
                    Spacer()
                    Button("Sign out") { account.signOut() }.disabled(account.busy)
                }
            }
            if let message = account.message { Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            Link("Manage usage and app access in ChatGPT", destination: URL(string: "https://chatgpt.com/settings/usage")!)
                .font(.caption)
            Text("Requires an eligible ChatGPT account and permission to use your plan. Your plan’s limits apply. Changing provider, account or model starts a new conversation.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
