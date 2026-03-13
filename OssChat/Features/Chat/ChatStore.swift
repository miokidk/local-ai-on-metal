import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class ChatStore: ObservableObject {
    enum ConnectionState: Equatable {
        case idle
        case checking
        case connected([String])
        case failed(String)
    }

    @Published private(set) var conversations: [Conversation] = []
    @Published var selectedConversationID: UUID?
    @Published var draftText: String = ""
    @Published var searchText: String = ""
    @Published var isShowingSettings: Bool = false
    @Published private(set) var availableModels: [String] = []
    @Published private(set) var connectionState: ConnectionState = .idle
    @Published var settings: AppSettings {
        didSet {
            persistSettings()
        }
    }

    private let persistence = ChatPersistence()
    private let client = ResponsesAPIClient()
    private let userDefaults = UserDefaults.standard
    private let settingsKey = "OssChat.Settings"

    private var saveTask: Task<Void, Never>?
    private var streamTasks: [UUID: Task<Void, Never>] = [:]

    init() {
        if
            let data = UserDefaults.standard.data(forKey: settingsKey),
            let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
        {
            settings = decoded
        } else {
            settings = AppSettings()
        }

        settings.registerModel(settings.selectedModel)

        Task {
            await loadPersistedState()
            refreshServerMetadata()
        }
    }

    var selectedConversation: Conversation? {
        guard let selectedConversationID else {
            return conversations.first
        }
        return conversations.first(where: { $0.id == selectedConversationID }) ?? conversations.first
    }

    var filteredConversations: [Conversation] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return conversations }

        return conversations.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.previewText.localizedCaseInsensitiveContains(query)
        }
    }

    var canRegenerateSelectedConversation: Bool {
        guard let conversation = selectedConversation else { return false }
        return canRegenerate(conversationID: conversation.id)
    }

    func loadPersistedState() async {
        if let state = await persistence.load() {
            conversations = state.conversations
            selectedConversationID = state.selectedConversationID ?? state.conversations.first?.id
        }

        if conversations.isEmpty {
            startNewConversation()
        } else if selectedConversationID == nil {
            selectedConversationID = conversations.first?.id
        }
    }

    func startNewConversation() {
        let conversation = Conversation()
        conversations.insert(conversation, at: 0)
        selectedConversationID = conversation.id
        draftText = ""
        scheduleSave()
    }

    func deleteConversation(_ conversationID: UUID) {
        cancelGeneration(for: conversationID)
        conversations.removeAll { $0.id == conversationID }

        if conversations.isEmpty {
            startNewConversation()
        } else if selectedConversationID == conversationID {
            selectedConversationID = conversations.first?.id
        }

        scheduleSave()
    }

    func sendCurrentDraft() {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let conversationID = ensureSelectedConversation()
        guard let index = indexForConversation(conversationID) else { return }

        let userMessage = ChatMessage(role: .user, content: text)
        conversations[index].messages.append(userMessage)
        updateTitleIfNeeded(for: index, using: text)
        touchConversation(at: index)
        draftText = ""

        requestAssistantReply(for: conversationID)
    }

    func cancelGenerationForSelectedConversation() {
        guard let selectedConversationID else { return }
        cancelGeneration(for: selectedConversationID)
    }

    func cancelGeneration(for conversationID: UUID) {
        streamTasks[conversationID]?.cancel()
        streamTasks[conversationID] = nil

        guard let conversationIndex = indexForConversation(conversationID),
              let assistantIndex = conversations[conversationIndex].messages.lastIndex(where: { $0.role == .assistant && $0.state == .streaming }) else {
            scheduleSave()
            return
        }

        if conversations[conversationIndex].messages[assistantIndex].trimmedContent.isEmpty,
           (conversations[conversationIndex].messages[assistantIndex].thoughts ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            conversations[conversationIndex].messages.remove(at: assistantIndex)
        } else {
            conversations[conversationIndex].messages[assistantIndex].state = .complete
        }

        touchConversation(at: conversationIndex)
    }

    func regenerateLastResponse() {
        guard let conversation = selectedConversation else { return }
        regenerateLastResponse(for: conversation.id)
    }

    func regenerateLastResponse(for conversationID: UUID) {
        guard canRegenerate(conversationID: conversationID),
              let conversationIndex = indexForConversation(conversationID) else { return }

        if conversations[conversationIndex].messages.last?.role == .assistant {
            conversations[conversationIndex].messages.removeLast()
        }
        touchConversation(at: conversationIndex)
        requestAssistantReply(for: conversationID)
    }

    func exportSelectedConversation() {
        guard let conversation = selectedConversation else { return }
        exportConversation(conversation)
    }

    func exportConversation(_ conversation: Conversation) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.plainText]
        panel.nameFieldStringValue = sanitizedFileName(from: conversation.title) + ".md"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try exportMarkdown(for: conversation).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            presentErrorMessage("Couldn’t export this conversation.")
        }
    }

    func selectModel(_ model: String) {
        settings.registerModel(model)
    }

    func selectReasoningEffort(_ effort: ReasoningEffort) {
        settings.selectedReasoningEffort = effort
    }

    func isStreaming(conversationID: UUID?) -> Bool {
        guard let conversationID else { return false }
        return streamTasks[conversationID] != nil
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func useOllamaDefaults() {
        settings.baseURLString = AppSettings.defaultBaseURL
        refreshServerMetadata()
    }

    func refreshServerMetadata() {
        guard let baseURL = settings.resolvedBaseURL else {
            connectionState = .failed("Enter a valid base URL.")
            return
        }

        let apiKey = settings.apiKey.nonEmpty
        connectionState = .checking

        Task { [weak self] in
            guard let self else { return }

            do {
                let metadata = try await client.resolveServerMetadata(preferredBaseURL: baseURL, apiKey: apiKey)
                self.applyResolvedServerMetadata(metadata)
            } catch {
                self.connectionState = .failed(self.friendlyMessage(for: error))
            }
        }
    }

    private func requestAssistantReply(for conversationID: UUID) {
        guard streamTasks[conversationID] == nil,
              let conversationIndex = indexForConversation(conversationID) else { return }

        let baseURLString = settings.baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = settings.resolvedBaseURL else {
            markAssistantError("The server URL is invalid: \(baseURLString)", in: conversationID)
            return
        }

        let assistantMessage = ChatMessage(role: .assistant, content: "", thoughts: nil, state: .streaming)
        conversations[conversationIndex].messages.append(assistantMessage)
        touchConversation(at: conversationIndex)

        let history = conversations[conversationIndex].messages.dropLast().filter {
            !$0.trimmedContent.isEmpty || (($0.thoughts ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        }

        let task = Task { [weak self] in
            guard let self else { return }

            do {
                let metadata = try await self.client.resolveServerMetadata(
                    preferredBaseURL: baseURL,
                    apiKey: self.settings.apiKey.nonEmpty
                )
                self.applyResolvedServerMetadata(metadata)

                let selectedModel = self.resolvePreferredModel(from: metadata.models)
                self.settings.registerModel(selectedModel)

                let request = ResponsesAPIRequest(
                    baseURL: metadata.baseURL,
                    apiKey: self.settings.apiKey.nonEmpty,
                    model: selectedModel,
                    reasoningEffort: self.settings.selectedReasoningEffort,
                    messages: Array(history)
                )

                let stream = self.client.streamResponse(for: request)
                for try await event in stream {
                    self.consume(event, conversationID: conversationID)
                }
                self.finishStreaming(in: conversationID)
            } catch is CancellationError {
                self.finishStreaming(in: conversationID, preservePartialResult: true)
            } catch {
                let message = self.friendlyMessage(for: error, requestedBaseURL: baseURLString)
                self.markAssistantError(message, in: conversationID)
                self.connectionState = .failed(message)
            }
        }

        streamTasks[conversationID] = task
    }

    private func consume(_ event: ResponsesAPIStreamEvent, conversationID: UUID) {
        guard let conversationIndex = indexForConversation(conversationID),
              let messageIndex = conversations[conversationIndex].messages.lastIndex(where: { $0.role == .assistant }) else { return }

        switch event {
        case .thoughtsDelta(let delta):
            conversations[conversationIndex].messages[messageIndex].thoughts = (conversations[conversationIndex].messages[messageIndex].thoughts ?? "") + delta
        case .outputDelta(let delta):
            conversations[conversationIndex].messages[messageIndex].content += delta
        case .completed(let finalText, let thoughts):
            if let finalText, finalText.count > conversations[conversationIndex].messages[messageIndex].content.count {
                conversations[conversationIndex].messages[messageIndex].content = finalText
            }
            if let thoughts, thoughts.count > (conversations[conversationIndex].messages[messageIndex].thoughts ?? "").count {
                conversations[conversationIndex].messages[messageIndex].thoughts = thoughts
            }
        }

        touchConversation(at: conversationIndex)
    }

    private func finishStreaming(in conversationID: UUID, preservePartialResult: Bool = false) {
        streamTasks[conversationID] = nil

        guard let conversationIndex = indexForConversation(conversationID),
              let messageIndex = conversations[conversationIndex].messages.lastIndex(where: { $0.role == .assistant }) else {
            scheduleSave()
            return
        }

        let hasVisibleContent = !conversations[conversationIndex].messages[messageIndex].trimmedContent.isEmpty
            || (conversations[conversationIndex].messages[messageIndex].thoughts ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

        if preservePartialResult || hasVisibleContent {
            conversations[conversationIndex].messages[messageIndex].state = .complete
        } else {
            conversations[conversationIndex].messages.remove(at: messageIndex)
        }

        touchConversation(at: conversationIndex)
    }

    private func markAssistantError(_ message: String, in conversationID: UUID) {
        streamTasks[conversationID]?.cancel()
        streamTasks[conversationID] = nil

        guard let conversationIndex = indexForConversation(conversationID),
              let assistantIndex = conversations[conversationIndex].messages.lastIndex(where: { $0.role == .assistant }) else {
            presentErrorMessage(message)
            return
        }

        conversations[conversationIndex].messages[assistantIndex].state = .error
        conversations[conversationIndex].messages[assistantIndex].errorText = message
        touchConversation(at: conversationIndex)
    }

    private func ensureSelectedConversation() -> UUID {
        if let selectedConversationID {
            return selectedConversationID
        }
        startNewConversation()
        return conversations[0].id
    }

    private func canRegenerate(conversationID: UUID) -> Bool {
        guard let index = indexForConversation(conversationID),
              !isStreaming(conversationID: conversationID),
              conversations[index].messages.contains(where: { $0.role == .user }) else {
            return false
        }

        if let last = conversations[index].messages.last {
            return last.role == .assistant || last.role == .user
        }
        return false
    }

    private func indexForConversation(_ conversationID: UUID) -> Int? {
        conversations.firstIndex(where: { $0.id == conversationID })
    }

    private func updateTitleIfNeeded(for conversationIndex: Int, using message: String) {
        guard conversations[conversationIndex].isUntitled else { return }

        let cleaned = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")

        let title = String(cleaned.prefix(48)).trimmingCharacters(in: .whitespacesAndNewlines)
        conversations[conversationIndex].title = title.isEmpty ? Conversation.untitledName : title
    }

    private func touchConversation(at index: Int) {
        guard conversations.indices.contains(index) else { return }
        conversations[index].updatedAt = Date()

        if index != 0 {
            let conversation = conversations.remove(at: index)
            conversations.insert(conversation, at: 0)
            selectedConversationID = conversation.id
        }

        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = PersistedChatState(conversations: conversations, selectedConversationID: selectedConversationID)
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            await persistence.save(snapshot)
        }
    }

    private func persistSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            userDefaults.set(data, forKey: settingsKey)
        }
    }

    private func exportMarkdown(for conversation: Conversation) -> String {
        var lines: [String] = ["# \(conversation.title)", ""]
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        for message in conversation.messages {
            let roleTitle = message.role == .user ? "User" : "Assistant"
            lines.append("## \(roleTitle) · \(formatter.string(from: message.createdAt))")
            lines.append("")

            if let thoughts = message.thoughts?.trimmingCharacters(in: .whitespacesAndNewlines), !thoughts.isEmpty {
                lines.append("<details>")
                lines.append("<summary>Thoughts</summary>")
                lines.append("")
                lines.append(thoughts)
                lines.append("")
                lines.append("</details>")
                lines.append("")
            }

            if !message.content.isEmpty {
                lines.append(message.content)
                lines.append("")
            }

            if let errorText = message.errorText {
                lines.append("> Error: \(errorText)")
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func sanitizedFileName(from title: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = title
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "OssChat Conversation" : cleaned
    }

    private func presentErrorMessage(_ message: String) {
        NSSound.beep()
        NSLog("OssChat error: %@", message)
    }

    private func applyResolvedServerMetadata(_ metadata: ResponsesServerMetadata) {
        availableModels = metadata.models
        connectionState = .connected(metadata.models)

        if settings.baseURLString != metadata.baseURL.absoluteString {
            settings.baseURLString = metadata.baseURL.absoluteString
        }

        let resolvedModel = resolvePreferredModel(from: metadata.models)
        if resolvedModel != settings.selectedModel {
            settings.registerModel(resolvedModel)
        }
    }

    private func resolvePreferredModel(from models: [String]) -> String {
        let selected = settings.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let available = models.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

        if available.contains(selected) {
            return selected
        }

        if let gptOssMatch = available.first(where: { $0.localizedCaseInsensitiveContains("gpt-oss") }) {
            return gptOssMatch
        }

        if let aliasMatch = available.first(where: { $0.localizedCaseInsensitiveContains("oss") }) {
            return aliasMatch
        }

        return available.first ?? selected
    }

    private func friendlyMessage(for error: Error, requestedBaseURL: String? = nil) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            if description.contains("Couldn’t connect"), let requestedBaseURL {
                return "\(description)\nTried: \(requestedBaseURL)"
            }
            return description
        }
        return error.localizedDescription
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : self
    }
}
