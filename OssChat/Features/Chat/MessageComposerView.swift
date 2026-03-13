import SwiftUI

@MainActor
struct MessageComposerView: View {
    @Binding var text: String
    let selectedModel: String
    let recentModels: [String]
    let selectedReasoningEffort: ReasoningEffort
    let isStreaming: Bool
    let canRegenerate: Bool
    let onSend: () -> Void
    let onCancel: () -> Void
    let onRegenerate: () -> Void
    let onModelSelected: (String) -> Void
    let onReasoningSelected: (ReasoningEffort) -> Void
    let onOpenSettings: () -> Void

    @State private var composerHeight: CGFloat = 48
    @FocusState private var isFocused: Bool

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isStreaming
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: Color.black.opacity(0.045), radius: 14, y: 8)

                if text.isEmpty {
                    Text("Message \(selectedModel)")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                }

                ExpandingTextView(
                    text: $text,
                    height: $composerHeight,
                    isFocused: $isFocused,
                    onSubmit: onSend
                )
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .frame(minHeight: 54, maxHeight: max(54, composerHeight + 20))

            HStack(spacing: 10) {
                PickerChip(title: selectedModel) {
                    ForEach(recentModels, id: \.self) { model in
                        Button(model) {
                            onModelSelected(model)
                        }
                    }
                }

                PickerChip(title: selectedReasoningEffort.title) {
                    ForEach(ReasoningEffort.allCases) { effort in
                        Button(effort.title) {
                            onReasoningSelected(effort)
                        }
                    }
                }

                Button {
                    onOpenSettings()
                } label: {
                    Label("Settings", systemImage: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Spacer()

                if canRegenerate && !isStreaming {
                    Button("Regenerate") {
                        onRegenerate()
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    isStreaming ? onCancel() : onSend()
                } label: {
                    Image(systemName: isStreaming ? "stop.fill" : "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 34, height: 34)
                        .background(isStreaming ? Color.red.opacity(0.88) : Color.black.opacity(canSend ? 0.88 : 0.28))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend && !isStreaming)
            }
        }
        .onAppear {
            isFocused = true
        }
    }
}

private struct PickerChip<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 6) {
                Text(title)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .bold))
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.gray.opacity(0.12))
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
