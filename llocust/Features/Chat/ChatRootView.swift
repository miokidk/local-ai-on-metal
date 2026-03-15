import SwiftUI

@MainActor
struct ChatRootView: View {
    @ObservedObject var store: ChatStore
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var sidebarWidth: CGFloat = 280

    var body: some View {
        Group {
            if store.isLaunchReady {
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
                .onPreferenceChange(SidebarWidthPreferenceKey.self) { width in
                    guard width > 0 else { return }
                    sidebarWidth = width
                }
            } else {
                LaunchScreenView(
                    errorMessage: store.launchErrorMessage,
                    onRetry: store.retryLaunchPreparation
                )
            }
        }
        .overlay(alignment: .top) {
            if store.isLaunchReady {
                UnifiedTitlebarOverlay(
                    sidebarWidth: isSidebarVisible ? sidebarWidth : 0
                )
            }
        }
        .sheet(isPresented: $store.isShowingSettings) {
            SettingsView(store: store)
        }
    }

    private var isSidebarVisible: Bool {
        columnVisibility != .detailOnly
    }
}

private struct UnifiedTitlebarOverlay: View {
    let sidebarWidth: CGFloat

    private let overlayHeight: CGFloat = 92
    private let detailOverlap: CGFloat = 14

    var body: some View {
        GeometryReader { geometry in
            let clampedSidebarWidth = min(max(sidebarWidth, 0), geometry.size.width)
            let detailStartX = max(clampedSidebarWidth - detailOverlap, 0)
            let detailWidth = max(geometry.size.width - detailStartX, 0)

            ZStack(alignment: .topLeading) {
                if detailWidth > 0 {
                    DetailTitlebarOverlay()
                        .frame(width: detailWidth, height: overlayHeight, alignment: .topLeading)
                        .offset(x: detailStartX)
                }

                HStack {
                    Spacer(minLength: 0)
                    LocustTitlebarImage()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            .frame(width: geometry.size.width, height: overlayHeight, alignment: .topLeading)
        }
        .frame(height: overlayHeight)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }
}

private struct DetailTitlebarOverlay: View {
    var body: some View {
        ZStack {
            TitlebarBlurSection()
            TitlebarTintOverlay()
        }
        .mask {
            DetailTitlebarMask()
        }
    }
}

private struct TitlebarTintOverlay: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: Color(nsColor: .windowBackgroundColor).opacity(0.96), location: 0),
                .init(color: Color(nsColor: .windowBackgroundColor).opacity(0.86), location: 0.42),
                .init(color: Color(nsColor: .windowBackgroundColor).opacity(0.18), location: 0.82),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private struct TitlebarBlurSection: View {
    var body: some View {
        WindowBlurView(material: .titlebar)
    }
}

private struct DetailTitlebarMask: View {
    private let edgeFadeWidth: CGFloat = 12

    var body: some View {
        GeometryReader { geometry in
            let fadeWidth = min(edgeFadeWidth, geometry.size.width)

            HStack(spacing: 0) {
                LinearGradient(
                    colors: [.clear, .white],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: fadeWidth)

                Rectangle()
                    .fill(.white)
                    .frame(maxWidth: .infinity)
            }
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white.opacity(0.9), location: 0.24),
                        .init(color: .white.opacity(0.42), location: 0.62),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
    }
}

private struct WindowBlurView: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: NSVisualEffectView) {
        view.material = material
        view.blendingMode = .withinWindow
        view.state = .active
    }
}

private struct LocustTitlebarImage: View {
    var body: some View {
        Image("LocustTitlebarMark")
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .aspectRatio(contentMode: .fit)
            .frame(width: 40, height: 20)
            .padding(.top, 15)
            .padding(.trailing, 16)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct LaunchScreenView: View {
    let errorMessage: String?
    let onRetry: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .controlBackgroundColor).opacity(0.8)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                Image("LocustMark")
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 186, height: 186)

                if let errorMessage {
                    VStack(spacing: 12) {
                        Text("Couldn’t start the local model")
                            .font(.system(size: 22, weight: .semibold))
                        Text(errorMessage)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                            .frame(maxWidth: 560)
                        Button("Try Again", action: onRetry)
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ProgressView()
                        .controlSize(.regular)
                    Text("Starting oss 20b…")
                        .font(.system(size: 22, weight: .semibold))
                    Text("The app will open as soon as the model is warm and ready.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(40)
        }
    }
}
