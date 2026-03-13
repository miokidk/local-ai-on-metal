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

struct ChatAttachment: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var fileName: String
    var contentType: String?
    var extractedText: String
    var characterCount: Int
    var wasTruncated: Bool = false

    var displayTitle: String {
        if wasTruncated {
            return "\(fileName) (truncated)"
        }
        return fileName
    }

    var modelInputText: String {
        var lines = ["Attached file: \(fileName)"]

        if let contentType, !contentType.isEmpty {
            lines.append("Content type: \(contentType)")
        }

        if wasTruncated {
            lines.append("Note: File content was truncated before being attached.")
        }

        lines.append("")
        lines.append(extractedText)
        return lines.joined(separator: "\n")
    }
}

struct ChatMessage: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var role: ChatRole
    var createdAt: Date = Date()
    var content: String
    var attachments: [ChatAttachment] = []
    var thoughts: String?
    var state: ChatMessageState = .complete
    var errorText: String?

    var trimmedContent: String {
        content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasVisibleContent: Bool {
        !trimmedContent.isEmpty || !attachments.isEmpty
    }

    var previewText: String {
        if !trimmedContent.isEmpty {
            return trimmedContent
        }

        guard let firstAttachment = attachments.first else {
            return ""
        }

        if attachments.count == 1 {
            return "Attached \(firstAttachment.fileName)"
        }

        return "Attached \(attachments.count) files"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case createdAt
        case content
        case attachments
        case thoughts
        case state
        case errorText
    }

    init(
        id: UUID = UUID(),
        role: ChatRole,
        createdAt: Date = Date(),
        content: String,
        attachments: [ChatAttachment] = [],
        thoughts: String? = nil,
        state: ChatMessageState = .complete,
        errorText: String? = nil
    ) {
        self.id = id
        self.role = role
        self.createdAt = createdAt
        self.content = content
        self.attachments = attachments
        self.thoughts = thoughts
        self.state = state
        self.errorText = errorText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try container.decode(ChatRole.self, forKey: .role)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        attachments = try container.decodeIfPresent([ChatAttachment].self, forKey: .attachments) ?? []
        thoughts = try container.decodeIfPresent(String.self, forKey: .thoughts)
        state = try container.decodeIfPresent(ChatMessageState.self, forKey: .state) ?? .complete
        errorText = try container.decodeIfPresent(String.self, forKey: .errorText)
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
        let latestText = messages.last(where: { $0.hasVisibleContent })?.previewText ?? "No messages yet"
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
