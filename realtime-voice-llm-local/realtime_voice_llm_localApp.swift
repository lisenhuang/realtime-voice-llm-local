import SwiftUI

@main
struct realtime_voice_llm_localApp: App {
    var body: some Scene {
        Window("Local Voice", id: "main") { ContentView() }
            .defaultSize(width: 1020, height: 760)
            .windowStyle(.hiddenTitleBar)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}
