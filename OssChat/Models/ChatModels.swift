import Foundation

enum ChatRole: String, Codable {
    case user
    case assistant
}

enum ChatMessageState: String, Codable {
    case complete
    case streaming
    case error
}

struct ChatMessage: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var role: ChatRole
    var createdAt: Date = Date()
    var content: String
    var thoughts: String?
    var state: ChatMessageState = .complete
    var errorText: String?

    var trimmedContent: String {
        content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct Conversation: Identifiable, Codable, Hashable {
    static let untitledName = "New Chat"

    var id: UUID = UUID()
    var title: String = Conversation.untitledName
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var messages: [ChatMessage] = []

    var previewText: String {
        let latestText = messages.last(where: { !$0.trimmedContent.isEmpty })?.trimmedContent ?? "No messages yet"
        return latestText.replacingOccurrences(of: "\n", with: " ")
    }

    var isUntitled: Bool {
        title == Conversation.untitledName
    }
}

struct PersistedChatState: Codable {
    var conversations: [Conversation]
    var selectedConversationID: UUID?
}
