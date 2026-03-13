import SwiftUI

@main
struct LlocustApp: App {
    @StateObject private var store = ChatStore()

    var body: some Scene {
        WindowGroup {
            ChatRootView(store: store)
                .frame(minWidth: 980, minHeight: 700)
        }
        .defaultSize(width: 1180, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            AppCommands(store: store)
        }
    }
}
