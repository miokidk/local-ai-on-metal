import AppKit
import SwiftUI

struct ExpandingTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    @FocusState.Binding var isFocused: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder

        let textView = ComposerTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = .systemFont(ofSize: 17)
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.textContainer?.lineFragmentPadding = 0
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.onSubmit = onSubmit
        textView.string = text

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.updateHeight()

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }

        if textView.string != text {
            textView.string = text
            context.coordinator.updateHeight()
        }

        textView.onSubmit = onSubmit

        if isFocused, scrollView.window?.firstResponder !== textView {
            DispatchQueue.main.async {
                scrollView.window?.makeFirstResponder(textView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ExpandingTextView
        weak var textView: ComposerTextView?

        init(parent: ExpandingTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            updateHeight()
        }

        func updateHeight() {
            guard let textView else { return }
            let width = max(textView.bounds.width, 300)
            let fittingSize = textView.sizeThatFits(in: NSSize(width: width, height: .greatestFiniteMagnitude))
            let newHeight = min(max(fittingSize.height, 24), 220)
            DispatchQueue.main.async {
                self.parent.height = newHeight
            }
        }
    }
}

final class ComposerTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturnKey = event.keyCode == 36 || event.keyCode == 76
        if isReturnKey && !event.modifierFlags.contains(.shift) {
            onSubmit?()
            return
        }

        super.keyDown(with: event)
    }

    func sizeThatFits(in size: NSSize) -> NSSize {
        guard let textContainer, let layoutManager else {
            return intrinsicContentSize
        }

        textContainer.containerSize = NSSize(width: size.width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        return NSSize(width: size.width, height: ceil(usedRect.height + textContainerInset.height * 2))
    }
}
