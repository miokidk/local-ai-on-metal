import SwiftUI

@MainActor
struct ConversationDetailView: View {
    @ObservedObject var store: ChatStore
    let conversation: Conversation?

    var body: some View {
        VStack(spacing: 0) {
            content
            contextCompactionBanner
            connectionBanner
            MessageComposerView(
                text: $store.draftText,
                attachments: $store.draftAttachments,
                selectedReasoningEffort: Binding(
                    get: { store.settings.selectedReasoningEffort },
                    set: { store.settings.selectedReasoningEffort = $0 }
                ),
                isStreaming: store.isStreaming(conversationID: conversation?.id),
                onAddAttachment: store.addDraftAttachments,
                onRemoveAttachment: store.removeDraftAttachment(_:),
                onSend: store.sendCurrentDraft,
                onCancel: store.cancelGenerationForSelectedConversation
            )
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    store.startNewConversation()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("New Chat")
            }
        }
    }

    @ViewBuilder
    private var contextCompactionBanner: some View {
        if let message = store.contextCompactionMessage(for: conversation?.id) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 10)
        }
    }

    @ViewBuilder
    private var connectionBanner: some View {
        switch store.connectionState {
        case .idle, .connected:
            EmptyView()
        case .checking:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Starting oss 20b…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 10)
        case .failed(let message):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.red.opacity(0.9))
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.red.opacity(0.9))
                    .textSelection(.enabled)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 10)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let conversation {
            if conversation.messages.isEmpty {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MessageListView(
                    conversation: conversation,
                    autoShowThoughts: store.settings.autoShowThoughts,
                    onCopy: store.copyToPasteboard(_:),
                    onRegenerate: {
                        store.regenerateLastResponse(for: conversation.id)
                    }
                )
            }
        } else {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
