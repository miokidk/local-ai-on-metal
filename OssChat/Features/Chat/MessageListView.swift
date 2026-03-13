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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 18) {
                    ForEach(Array(conversation.messages.enumerated()), id: \.element.id) { index, message in
                        MessageBubbleView(
                            message: message,
                            isLastAssistantMessage: index == conversation.messages.indices.last && message.role == .assistant,
                            autoShowThoughts: autoShowThoughts,
                            onCopy: {
                                let combined = [message.thoughts, message.content]
                                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                                    .filter { !$0.isEmpty }
                                    .joined(separator: "\n\n")
                                onCopy(combined)
                            },
                            onRegenerate: onRegenerate
                        )
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("message-bottom")
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .background(
                    ScrollViewOffsetObserver { isNearBottom in
                        userIsNearBottom = isNearBottom
                    }
                    .frame(width: 0, height: 0)
                )
            }
            .background(Color(nsColor: .underPageBackgroundColor))
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

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
            HStack {
                if message.role == .user { Spacer(minLength: 80) }

                VStack(alignment: .leading, spacing: 10) {
                    if let thoughts = message.thoughts?.trimmingCharacters(in: .whitespacesAndNewlines), !thoughts.isEmpty {
                        ThoughtsDisclosureView(
                            thoughts: thoughts,
                            startsExpanded: autoShowThoughts || message.state == .streaming
                        )
                    }

                    if !message.content.isEmpty {
                        MarkdownTextView(markdown: message.content)
                    } else if message.role == .assistant && message.state == .streaming {
                        Text("Thinking…")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
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
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: 760, alignment: .leading)
                .background(bubbleBackground)
                .overlay(alignment: .topTrailing) {
                    if isHovering {
                        HStack(spacing: 6) {
                            BubbleActionButton(systemImage: "doc.on.doc", action: onCopy)
                            if isLastAssistantMessage && message.role == .assistant && message.state != .streaming {
                                BubbleActionButton(systemImage: "arrow.clockwise", action: onRegenerate)
                            }
                        }
                        .padding(8)
                    }
                }
                .onHover { isHovering = $0 }

                if message.role == .assistant { Spacer(minLength: 80) }
            }

            Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(message.role == .user ? .trailing : .leading, 6)
        }
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

    private var bubbleBackground: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(message.role == .user ? Color.accentColor.opacity(0.10) : Color.white.opacity(0.9))
            .shadow(color: Color.black.opacity(message.role == .user ? 0.015 : 0.04), radius: 12, y: 8)
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
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
    }
}
