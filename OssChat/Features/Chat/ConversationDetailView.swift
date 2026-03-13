import AppKit
import SwiftUI

@MainActor
struct ConversationDetailView: View {
    @ObservedObject var store: ChatStore
    let conversation: Conversation?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            content
            Divider()
            MessageComposerView(
                text: $store.draftText,
                selectedModel: store.settings.selectedModel,
                recentModels: store.settings.sanitizedRecentModels,
                selectedReasoningEffort: store.settings.selectedReasoningEffort,
                isStreaming: store.isStreaming(conversationID: conversation?.id),
                canRegenerate: store.canRegenerateSelectedConversation,
                onSend: store.sendCurrentDraft,
                onCancel: store.cancelGenerationForSelectedConversation,
                onRegenerate: store.regenerateLastResponse,
                onModelSelected: store.selectModel(_:),
                onReasoningSelected: store.selectReasoningEffort(_:),
                onOpenSettings: { store.isShowingSettings = true }
            )
            .padding(20)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button(action: toggleSidebar) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(conversation?.title ?? "OssChat")
                    .font(.system(size: 15, weight: .semibold))
                Text(store.settings.selectedModel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let conversation, store.isStreaming(conversationID: conversation.id) {
                Label("Generating", systemImage: "bolt.horizontal.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Button("New Chat") {
                store.startNewConversation()
            }
            .buttonStyle(.bordered)

            Button {
                store.exportSelectedConversation()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .disabled(conversation == nil)

            Button {
                store.isShowingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.95))
    }

    @ViewBuilder
    private var content: some View {
        if let conversation {
            if conversation.messages.isEmpty {
                emptyState
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
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 82, height: 82)
                    .shadow(color: Color.black.opacity(0.04), radius: 18, y: 10)

                Image(systemName: "message.badge.waveform")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(Color(red: 0.20, green: 0.28, blue: 0.38))
            }

            VStack(spacing: 8) {
                Text("Ask your local model anything")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.92))
                Text("Fast, local, minimal chat for your gpt-oss server.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(40)
    }

    private func toggleSidebar() {
        NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
    }
}
