import SwiftUI

@MainActor
struct AppCommands: Commands {
    @ObservedObject var store: ChatStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat") {
                store.startNewConversation()
            }
            .keyboardShortcut("n")
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                store.isShowingSettings = true
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandMenu("Chat") {
            Button("Export Conversation…") {
                store.exportSelectedConversation()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(store.selectedConversation == nil)

            Button("Regenerate Last Response") {
                store.regenerateLastResponse()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!store.canRegenerateSelectedConversation)
        }
    }
}
