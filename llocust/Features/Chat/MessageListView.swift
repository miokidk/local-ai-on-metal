import SwiftUI

@MainActor
struct MessageListView: View {
    let conversation: Conversation
    let autoShowThoughts: Bool
    let onCopy: (String) -> Void
    let onRegenerate: () -> Void

    @State private var userIsNearBottom = true

    private var scrollTrigger: String {
        let last = conversation.messages.last
        return [
            "\(conversation.messages.count)",
            last?.id.uuidString ?? "none",
            "\(last?.content.count ?? 0)",
            "\(last?.thoughts?.count ?? 0)",
            last?.state.rawValue ?? "complete"
        ].joined(separator: "|")
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(Array(conversation.messages.enumerated()), id: \.element.id) { index, message in
                            MessageBubbleView(
                                message: message,
                                isLastAssistantMessage: index == conversation.messages.indices.last && message.role == .assistant,
                                autoShowThoughts: autoShowThoughts,
                                onCopy: {
                                    var segments: [String] = []

                                    if let thoughts = message.thoughts?.trimmingCharacters(in: .whitespacesAndNewlines), !thoughts.isEmpty {
                                        segments.append(thoughts)
                                    }

                                    if !message.trimmedContent.isEmpty {
                                        segments.append(message.content)
                                    }

                                    segments.append(contentsOf: message.attachments.map(\.modelInputText))
                                    let combined = segments.joined(separator: "\n\n")
                                    onCopy(combined)
                                },
                                onRegenerate: onRegenerate
                            )
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("message-bottom")
                    }
                    .frame(width: max(geometry.size.width - 48, 0), alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 32)
                    .background(
                        ScrollViewOffsetObserver { isNearBottom in
                            userIsNearBottom = isNearBottom
                        }
                        .frame(width: 0, height: 0)
                    )
                }
                .background(Color(nsColor: .windowBackgroundColor))
                .onAppear {
                    scrollToBottom(proxy, animated: false)
                }
                .onChange(of: conversation.id) {
                    userIsNearBottom = true
                    scrollToBottom(proxy, animated: false)
                }
                .onChange(of: scrollTrigger) {
                    guard userIsNearBottom else { return }
                    scrollToBottom(proxy, animated: true)
                }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        let action = {
            proxy.scrollTo("message-bottom", anchor: .bottom)
        }

        if animated {
            withAnimation(.easeOut(duration: 0.18), action)
        } else {
            action()
        }
    }
}

private struct MessageBubbleView: View {
    let message: ChatMessage
    let isLastAssistantMessage: Bool
    let autoShowThoughts: Bool
    let onCopy: () -> Void
    let onRegenerate: () -> Void

    @State private var isHovering = false

    private var trimmedThoughts: String? {
        message.thoughts?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    private var shouldShowThoughtsDisclosure: Bool {
        message.role == .assistant && (message.isThoughtsStreaming || trimmedThoughts != nil)
    }

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
            messageRow

            Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
                .padding(message.role == .user ? .trailing : .leading, 6)
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .contextMenu {
            Button("Copy") {
                onCopy()
            }

            if isLastAssistantMessage && message.role == .assistant && message.state != .streaming {
                Button("Regenerate") {
                    onRegenerate()
                }
            }
        }
    }

    @ViewBuilder
    private var messageRow: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 0)
                messageCard
                    .frame(maxWidth: 620, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            messageCard
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var messageCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if shouldShowThoughtsDisclosure {
                ThoughtsDisclosureView(
                    thoughts: trimmedThoughts,
                    isStreaming: message.isThoughtsStreaming,
                    startsExpanded: autoShowThoughts
                )
            }

            if !message.content.isEmpty {
                MarkdownTextView(markdown: message.content, fillsWidth: message.role != .user)
            }

            if !message.attachments.isEmpty {
                AttachmentListView(attachments: message.attachments)
            }

            if let errorText = message.errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.red.opacity(0.9))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.red.opacity(0.08))
                    )
            }
        }
        .padding(.horizontal, message.role == .user ? 16 : 0)
        .padding(.vertical, message.role == .user ? 14 : 0)
        .background(bubbleBackground)
        .overlay(alignment: .topTrailing) {
            if isHovering {
                HStack(spacing: 6) {
                    BubbleActionButton(systemImage: "doc.on.doc", action: onCopy)
                    if isLastAssistantMessage && message.role == .assistant && message.state != .streaming {
                        BubbleActionButton(systemImage: "arrow.clockwise", action: onRegenerate)
                    }
                }
                .padding(message.role == .user ? 8 : 0)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        if message.role == .user {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.accentColor.opacity(0.14))
        } else {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.clear)
        }
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

private struct BubbleActionButton: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(Color(nsColor: .controlBackgroundColor), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct AttachmentListView: View {
    let attachments: [ChatAttachment]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(attachments) { attachment in
                HStack(spacing: 10) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attachment.displayTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text("\(attachment.characterCount.formatted()) characters")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.85))
                )
            }
        }
    }
}
