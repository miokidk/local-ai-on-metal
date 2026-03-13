import SwiftUI

@MainActor
struct SidebarView: View {
    @ObservedObject var store: ChatStore
    let showsSettingsToolbarItem: Bool

    var body: some View {
        List(selection: $store.selectedConversationID) {
            ForEach(store.conversations) { conversation in
                SidebarRow(conversation: conversation)
                    .tag(conversation.id)
                    .contextMenu {
                        Button("Export…") {
                            store.exportConversation(conversation)
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            store.deleteConversation(conversation.id)
                        }
                    }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            if showsSettingsToolbarItem {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        store.isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .help("Settings")
                }
            }
        }
        .frame(minWidth: 230)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SidebarRow: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(conversation.title)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)

            if !conversation.previewText.isEmpty {
                Text(conversation.previewText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 8)
    }
}
