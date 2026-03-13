import AppKit
import SwiftUI

struct ScrollViewOffsetObserver: NSViewRepresentable {
    let onOffsetChange: (Bool) -> Void

    func makeNSView(context: Context) -> ScrollObservationView {
        let view = ScrollObservationView()
        view.onOffsetChange = onOffsetChange
        return view
    }

    func updateNSView(_ nsView: ScrollObservationView, context: Context) {
        nsView.onOffsetChange = onOffsetChange
        DispatchQueue.main.async {
            nsView.attachIfNeeded()
        }
    }
}

final class ScrollObservationView: NSView {
    var onOffsetChange: ((Bool) -> Void)?

    private weak var observedScrollView: NSScrollView?
    private var observer: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.attachIfNeeded()
        }
    }

    func attachIfNeeded() {
        if let scrollView = enclosingScrollView, observedScrollView !== scrollView {
            detach()
            observedScrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.reportOffset()
            }
        }
        reportOffset()
    }

    private func reportOffset() {
        guard let scrollView = observedScrollView else { return }
        let visibleMaxY = scrollView.contentView.bounds.maxY
        let contentHeight = scrollView.documentView?.bounds.height ?? 0
        onOffsetChange?(contentHeight - visibleMaxY < 140)
    }

    private func detach() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    deinit {
        detach()
    }
}
