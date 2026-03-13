import SwiftUI

@MainActor
struct SidebarView: View {
    @ObservedObject var store: ChatStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("OssChat")
                    .font(.system(size: 22, weight: .semibold))

                Spacer()

                Button {
                    store.startNewConversation()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 12)

            List(selection: $store.selectedConversationID) {
                ForEach(store.filteredConversations) { conversation in
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
            .searchable(text: $store.searchText, prompt: "Search chats")
        }
        .frame(minWidth: 270)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SidebarRow: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(conversation.title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)

            Text(conversation.previewText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Text(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}
