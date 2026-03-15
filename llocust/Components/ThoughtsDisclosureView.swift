import SwiftUI

struct ThoughtsDisclosureView: View {
    let thoughts: String?
    let isStreaming: Bool
    let startsExpanded: Bool

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if let thoughts, !thoughts.isEmpty {
                MarkdownTextView(markdown: thoughts, style: .subdued)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.gray.opacity(0.06))
                    )
                    .padding(.top, 8)
            }
        } label: {
            HStack(spacing: 0) {
                Text(isStreaming ? "Thinking..." : "Thoughts")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.secondary.opacity(0.78))

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                isExpanded.toggle()
            }
        }
        .onAppear {
            isExpanded = startsExpanded
        }
    }
}
