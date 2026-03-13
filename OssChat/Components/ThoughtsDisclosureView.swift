import SwiftUI

struct ThoughtsDisclosureView: View {
    let thoughts: String
    let startsExpanded: Bool

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            MarkdownTextView(markdown: thoughts, style: .subdued)
                .padding(.top, 8)
        } label: {
            Text("Reasoning")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.secondary.opacity(0.78))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.gray.opacity(0.06))
        )
        .onAppear {
            isExpanded = startsExpanded
        }
    }
}
