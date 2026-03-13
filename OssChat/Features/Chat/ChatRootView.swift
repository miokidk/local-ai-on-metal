import SwiftUI

@MainActor
struct ChatRootView: View {
    @ObservedObject var store: ChatStore

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
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
    }
}
