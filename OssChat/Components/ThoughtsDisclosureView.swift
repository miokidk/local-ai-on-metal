import SwiftUI

struct ThoughtsDisclosureView: View {
    let thoughts: String
    let startsExpanded: Bool

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            MarkdownTextView(markdown: thoughts)
                .padding(.top, 8)
        } label: {
            Label("Thoughts", systemImage: "brain.head.profile")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.gray.opacity(0.08))
        )
        .onAppear {
            isExpanded = startsExpanded
        }
    }
}
