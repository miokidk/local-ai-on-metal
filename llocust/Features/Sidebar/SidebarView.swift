import SwiftUI

@MainActor
struct SidebarView: View {
    @ObservedObject var store: ChatStore
    let showsSettingsToolbarItem: Bool

    @State private var suppressButtonInteractions = false

    var body: some View {
        List(selection: $store.selectedConversationID) {
            ForEach(store.conversations) { conversation in
                SidebarRow(
                    conversation: conversation,
                    interactionsEnabled: !suppressButtonInteractions,
                    onDelete: {
                        store.deleteConversation(conversation.id)
                    }
                )
                    .tag(conversation.id)
                    .contextMenu {
                        Button("Export…") {
                            store.exportConversation(conversation)
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            store.deleteConversation(conversation.id)
                        }
                    }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            if showsSettingsToolbarItem {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        store.isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .help("Settings")
                    .disabled(suppressButtonInteractions)
                }
            }
        }
        .frame(minWidth: 230)
        .background(Color(nsColor: .windowBackgroundColor))
        .background {
            GeometryReader { geometry in
                Color.clear
                    .preference(key: SidebarWidthPreferenceKey.self, value: geometry.size.width)
            }
        }
        .background(
            PointerActivityMonitor {
                suppressButtonInteractions = false
            }
        )
        .onAppear {
            suppressButtonInteractions = false
        }
        .onChange(of: showsSettingsToolbarItem) { oldValue, newValue in
            if !oldValue && newValue {
                suppressButtonInteractions = true
            } else if !newValue {
                suppressButtonInteractions = false
            }
        }
    }
}

private struct SidebarRow: View {
    let conversation: Conversation
    let interactionsEnabled: Bool
    let onDelete: () -> Void

    @State private var isHovering = false
    @State private var isHoveringDeleteButton = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(conversation.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)

                if !conversation.previewText.isEmpty {
                    Text(conversation.previewText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isHoveringDeleteButton ? Color.red : .secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Delete Chat")
            .opacity(isHovering && interactionsEnabled ? 1 : 0)
            .allowsHitTesting(isHovering && interactionsEnabled)
            .onHover { hovering in
                guard interactionsEnabled else {
                    isHoveringDeleteButton = false
                    return
                }
                isHoveringDeleteButton = hovering
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovering in
            guard interactionsEnabled else {
                isHovering = false
                isHoveringDeleteButton = false
                return
            }
            isHovering = hovering
            if !hovering {
                isHoveringDeleteButton = false
            }
        }
        .onChange(of: interactionsEnabled) { _, enabled in
            if !enabled {
                isHovering = false
                isHoveringDeleteButton = false
            }
        }
    }
}

struct SidebarWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct PointerActivityMonitor: NSViewRepresentable {
    let onActivity: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onActivity: onActivity)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onActivity = onActivity
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        var onActivity: @MainActor () -> Void
        private var monitor: Any?

        init(onActivity: @escaping @MainActor () -> Void) {
            self.onActivity = onActivity
        }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
            ) { [weak self] event in
                guard let self else { return event }
                Task { @MainActor in
                    self.onActivity()
                }
                return event
            }
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}
