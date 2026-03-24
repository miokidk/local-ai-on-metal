import SwiftUI

@MainActor
struct MessageComposerView: View {
    @Binding var text: String
    @Binding var attachments: [ChatAttachment]
    @Binding var selectedReasoningEffort: ReasoningEffort
    @Binding var selectedResponseMode: AssistantResponseMode
    let isStreaming: Bool
    let onAddAttachment: () -> Void
    let onRemoveAttachment: (UUID) -> Void
    let onSend: () -> Void
    let onCancel: () -> Void

    @State private var composerHeight: CGFloat = 28
    @FocusState private var isFocused: Bool

    private var canSend: Bool {
        (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty) && !isStreaming
    }

    private var composerBottomPadding: CGFloat {
        attachments.isEmpty ? 58 : 100
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(nsColor: .windowBackgroundColor),
                            Color(nsColor: .controlBackgroundColor)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(Color.white.opacity(0.65), lineWidth: 1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )

            if text.isEmpty && attachments.isEmpty {
                Text("Send a message")
                    .font(AppTypography.readingFont(size: 19, weight: .light))
                    .tracking(AppTypography.bodyTracking)
                    .foregroundStyle(Color.secondary.opacity(0.9))
                    .padding(.horizontal, 22)
                    .padding(.top, 18)
            }

            ExpandingTextView(
                text: $text,
                height: $composerHeight,
                isFocused: $isFocused,
                onSubmit: onSend
            )
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, composerBottomPadding)

            VStack(alignment: .leading, spacing: 10) {
                if !attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(attachments) { attachment in
                                ComposerAttachmentChip(
                                    attachment: attachment,
                                    onRemove: {
                                        onRemoveAttachment(attachment.id)
                                    }
                                )
                            }
                        }
                    }
                }

                HStack(spacing: 12) {
                    Button(action: onAddAttachment) {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.primary.opacity(0.82))
                            .frame(width: 30, height: 30)
                            .background(
                                Circle()
                                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.9))
                            )
                    }
                    .buttonStyle(.plain)

                    Menu {
                        ForEach(ReasoningEffort.allCases) { effort in
                            Button(effort.title) {
                                selectedReasoningEffort = effort
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(selectedReasoningEffort.title)
                                .font(.system(size: 15, weight: .regular))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(Color.secondary.opacity(0.72))
                        .contentShape(Rectangle())
                    }
                    .menuIndicator(.hidden)
                    .buttonStyle(.plain)
                    .fixedSize()

                    Menu {
                        ForEach(AssistantResponseMode.allCases) { mode in
                            Button(mode.title) {
                                selectedResponseMode = mode
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(selectedResponseMode.title)
                                .font(.system(size: 15, weight: .regular))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(Color.secondary.opacity(0.72))
                        .contentShape(Rectangle())
                    }
                    .menuIndicator(.hidden)
                    .buttonStyle(.plain)
                    .fixedSize()

                    Spacer()

                    Button {
                        isStreaming ? onCancel() : onSend()
                    } label: {
                        Image(systemName: isStreaming ? "stop.fill" : "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(
                                isStreaming
                                    ? Color.red.opacity(0.88)
                                    : Color.black.opacity(canSend ? 0.92 : 0.22)
                            )
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend && !isStreaming)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .frame(minHeight: 128, maxHeight: max(128, composerHeight + (attachments.isEmpty ? 88 : 126)))
        .shadow(color: Color.black.opacity(0.16), radius: 26, x: 0, y: 16)
        .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 4)
        .onAppear {
            isFocused = true
        }
    }
}

private struct ComposerAttachmentChip: View {
    let attachment: ChatAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc")
                .font(.system(size: 11, weight: .semibold))
            Text(attachment.displayTitle)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18)
                    .background(Color.black.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Color.primary.opacity(0.82))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.92))
        )
    }
}
