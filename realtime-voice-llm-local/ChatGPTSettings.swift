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
                }.disabled(account.busy || account.testingWeb)
            }
            if account.busy {
                HStack { ProgressView().controlSize(.small); Text("Connecting…"); Spacer(); if account.canCancel { Button("Cancel") { account.cancelLogin() } } }
            } else {
                HStack {
                    Button("Continue with ChatGPT") { account.signIn() }.buttonStyle(.borderedProminent).disabled(account.testingWeb)
                    if !account.profiles.isEmpty { Button("Add account") { account.signIn(addAccount: true) }.disabled(account.testingWeb) }
                }
            }
            if account.connected {
                Text("Using your ChatGPT plan").font(.subheadline.weight(.medium))
                if !account.models.isEmpty {
                    Picker("Text model", selection: Binding(get: { account.modelID }, set: { account.chooseModel($0) })) {
                        ForEach(account.models) { model in Text(model.name).tag(model.id) }
                    }.disabled(account.busy || account.testingWeb)
                    Picker("Reasoning level", selection: Binding(get: { account.reasoningChoice }, set: { account.chooseReasoning($0) })) {
                        Text("Model default").tag("default")
                        ForEach(account.selectedModel?.reasoningLevels ?? [], id: \.self) { effort in
                            Text(ChatGPTModel.effortLabel(effort)).tag(effort)
                        }
                    }.disabled(account.busy || account.testingWeb || (account.selectedModel?.reasoningLevels.isEmpty ?? true))
                    Text((account.selectedModel?.reasoningLevels.isEmpty ?? true)
                         ? "This model does not advertise adjustable reasoning levels. Using its default."
                         : "Lower levels usually reply faster. Higher levels spend more time thinking. Saved for this model and account; applies from your next reply.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Web search provider").font(.subheadline.weight(.medium))
                    Picker("Search with", selection: Binding(get: { account.effectiveSearchProvider }, set: { account.chooseWebSearch($0) })) {
                        Text("App tools · DuckDuckGo + weather").tag(WebSearchProvider.appTools)
                        Text("Model’s built-in web search").tag(WebSearchProvider.model).disabled(account.currentWebCheck?.isRecentSuccess != true)
                    }.disabled(account.testingWeb || account.busy)
                    if account.testingWeb {
                        HStack { ProgressView().controlSize(.small); Text(account.webTestProgress).font(.caption); Spacer(); Button("Cancel test") { account.cancelWebTest() } }
                    } else {
                        HStack {
                            Button("Test model web search") { account.testWebSearch() }
                            Button("Test all models") { account.testWebSearch(allModels: true) }
                        }.disabled(account.busy || account.models.isEmpty)
                    }
                    if let check = account.currentWebCheck {
                        Text(check.summary).font(.caption.weight(.medium)).foregroundStyle(check.isRecentSuccess ? Color.green : Color.orange)
                        Text(check.detail).font(.caption).foregroundStyle(.secondary)
                        Text("Checked \(check.date.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                    } else { Text("Run the test to enable built-in web search for this model and reasoning level.").font(.caption).foregroundStyle(.secondary) }
                    Text("Tests use your ChatGPT allowance and end any active call. All-model tests use this reasoning level where supported. Timings include the complete request and can vary. A successful check enables model search for 7 days; app tools remain available. Changes apply to the next reply. The call screen’s Web search switch controls both providers.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !account.accountWebChecks.isEmpty {
                        DisclosureGroup("Results across models") {
                            ForEach(account.accountWebChecks, id: \.date) { check in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(check.model).font(.caption.weight(.medium))
                                    Text(check.summary).font(.caption).foregroundStyle(check.passed ? Color.green : Color.orange)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
                            }
                        }.font(.caption)
                    }
                }
                HStack {
                    Button("Refresh models") { Task { await account.loadModels() } }.disabled(account.busy || account.testingWeb)
                    Spacer()
                    Button("Sign out") { account.signOut() }.disabled(account.busy || account.testingWeb)
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
