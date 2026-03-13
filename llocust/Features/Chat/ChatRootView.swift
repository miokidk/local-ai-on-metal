import SwiftUI

@MainActor
struct ChatRootView: View {
    @ObservedObject var store: ChatStore
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                store: store,
                showsSettingsToolbarItem: isSidebarVisible
            )
        } detail: {
            ConversationDetailView(
                store: store,
                conversation: store.selectedConversation
            )
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $store.isShowingSettings) {
            SettingsView(store: store)
        }
        .background(TitlebarLocustAccessoryInstaller())
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.startNewConversation()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("New Chat")
            }
        }
    }

    private var isSidebarVisible: Bool {
        columnVisibility != .detailOnly
    }
}

private struct TitlebarLocustAccessoryInstaller: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.installIfNeeded(for: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.installIfNeeded(for: nsView.window)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeAccessory()
    }

    final class Coordinator {
        private weak var window: NSWindow?
        private weak var accessory: NSTitlebarAccessoryViewController?

        func installIfNeeded(for window: NSWindow?) {
            guard let window else { return }
            guard self.window !== window || accessory == nil else { return }

            removeAccessory()

            let accessory = NSTitlebarAccessoryViewController()
            accessory.layoutAttribute = .right
            accessory.fullScreenMinHeight = 32

            let hostingView = NSHostingView(rootView: LocustTitlebarImage())
            hostingView.frame = NSRect(x: 0, y: 0, width: 82, height: 36)
            accessory.view = hostingView

            window.addTitlebarAccessoryViewController(accessory)

            self.window = window
            self.accessory = accessory
        }

        func removeAccessory() {
            guard let accessory, let window else { return }
            if let index = window.titlebarAccessoryViewControllers.firstIndex(of: accessory) {
                window.removeTitlebarAccessoryViewController(at: index)
            }
            self.accessory = nil
            self.window = nil
        }
    }
}

private struct LocustTitlebarImage: View {
    var body: some View {
        HStack {
            Spacer(minLength: 0)

            Image("LocustMark")
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .aspectRatio(contentMode: .fit)
                .frame(width: 62, height: 30)
                .padding(.trailing, 8)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .frame(width: 82, height: 36, alignment: .trailing)
    }
}
