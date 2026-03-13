import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class ChatStore: ObservableObject {
    private static let emptyResponseError = "The model finished without returning an answer. Try regenerating, lowering reasoning effort, or checking the local server logs."
    private static let maxAttachmentFileSize = 1_000_000
    private static let maxAttachmentCharacterCount = 120_000
    private static let maxDraftAttachmentCharacterCount = 360_000

    enum ConnectionState: Equatable {
        case idle
        case checking
        case connected([String])
        case failed(String)
    }

    @Published private(set) var conversations: [Conversation] = []
    @Published var selectedConversationID: UUID?
    @Published var draftText: String = ""
    @Published var draftAttachments: [ChatAttachment] = []
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
    private let localServer = LocalModelServer()
    private let userDefaults = UserDefaults.standard
    private let settingsKey = "llocust.Settings"

    private var saveTask: Task<Void, Never>?
    private var streamTasks: [UUID: Task<Void, Never>] = [:]
    private var streamRequestIDs: [UUID: String] = [:]
    private let pinnedBaseURL = URL(string: AppSettings.defaultBaseURL)!

    init() {
        if
            let data = userDefaults.data(forKey: settingsKey),
            let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
        {
            settings = decoded
        } else {
            settings = AppSettings()
        }

        settings.normalizeForSingleModel()
        persistSettings()

        Task {
            await loadPersistedState()
            await refreshServerMetadataNow()
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
        draftAttachments = []
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
        let attachments = draftAttachments
        guard !text.isEmpty || !attachments.isEmpty else { return }

        let conversationID = ensureSelectedConversation()
        guard let index = indexForConversation(conversationID) else { return }

        let userMessage = ChatMessage(role: .user, content: text, attachments: attachments)
        conversations[index].messages.append(userMessage)
        updateTitleIfNeeded(for: index, using: userMessage.previewText)
        touchConversation(at: index)
        draftText = ""
        draftAttachments = []

        requestAssistantReply(for: conversationID)
    }

    func addDraftAttachments() {
        let panel = NSOpenPanel()
        panel.prompt = "Attach"
        panel.message = "Choose text files to attach to your message."
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK else { return }

        do {
            let attachments = try loadAttachments(from: panel.urls)
            guard !attachments.isEmpty else { return }
            draftAttachments.append(contentsOf: attachments)
        } catch {
            presentErrorMessage(friendlyAttachmentErrorMessage(for: error))
        }
    }

    func removeDraftAttachment(_ attachmentID: UUID) {
        draftAttachments.removeAll { $0.id == attachmentID }
    }

    func cancelGenerationForSelectedConversation() {
        stopAllModelActivity()
    }

    func cancelGeneration(for conversationID: UUID) {
        streamTasks[conversationID]?.cancel()
        streamTasks[conversationID] = nil
        streamRequestIDs[conversationID] = nil

        guard let conversationIndex = indexForConversation(conversationID),
              let assistantIndex = conversations[conversationIndex].messages.lastIndex(where: { $0.role == .assistant && $0.state == .streaming }) else {
            scheduleSave()
            return
        }

        if conversations[conversationIndex].messages[assistantIndex].trimmedContent.isEmpty,
           conversations[conversationIndex].messages[assistantIndex].attachments.isEmpty,
           (conversations[conversationIndex].messages[assistantIndex].thoughts ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            conversations[conversationIndex].messages.remove(at: assistantIndex)
        } else {
            conversations[conversationIndex].messages[assistantIndex].state = .complete
        }

        touchConversation(at: conversationIndex)
    }

    func stopAllModelActivity() {
        let requestIDs = Array(streamRequestIDs.values)
        let conversationIDs = Array(streamTasks.keys)
        let apiKey = settings.apiKey.nonEmpty
        let baseURL = pinnedBaseURL

        conversationIDs.forEach(cancelGeneration(for:))

        guard !requestIDs.isEmpty else { return }

        Task { [client] in
            try? await client.cancelResponses(baseURL: baseURL, apiKey: apiKey, requestIDs: requestIDs)
        }
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

    func refreshServerMetadata() {
        settings.normalizeForSingleModel()
        connectionState = .checking

        Task { [weak self] in
            await self?.refreshServerMetadataNow()
        }
    }

    private func requestAssistantReply(for conversationID: UUID) {
        guard streamTasks[conversationID] == nil,
              let conversationIndex = indexForConversation(conversationID) else { return }

        settings.normalizeForSingleModel()
        let baseURLString = AppSettings.defaultBaseURL
        let baseURL = pinnedBaseURL

        let assistantMessage = ChatMessage(role: .assistant, content: "", thoughts: nil, state: .streaming)
        conversations[conversationIndex].messages.append(assistantMessage)
        touchConversation(at: conversationIndex)

        let history = conversations[conversationIndex].messages.dropLast().filter { $0.hasVisibleContent }
        let requestID = UUID().uuidString

        let task = Task { [weak self] in
            guard let self else { return }

            do {
                var didAttemptRecovery = false

                while true {
                    do {
                        try await self.localServer.ensureRunning()
                        let metadata = try await self.client.resolveServerMetadata(
                            preferredBaseURL: baseURL,
                            apiKey: self.settings.apiKey.nonEmpty
                        )
                        self.applyResolvedServerMetadata(metadata)

                        let selectedModel = self.resolvePreferredModel(from: metadata.models)
                        self.settings.registerModel(selectedModel)

                        let request = ResponsesAPIRequest(
                            requestID: requestID,
                            baseURL: metadata.baseURL,
                            apiKey: self.settings.apiKey.nonEmpty,
                            model: selectedModel,
                            reasoningEffort: self.settings.selectedReasoningEffort,
                            repeatPenalty: self.settings.repeatPenalty,
                            instructions: self.settings.trimmedSystemInstructions,
                            messages: Array(history)
                        )

                        let stream = self.client.streamResponse(for: request)
                        for try await event in stream {
                            self.consume(event, conversationID: conversationID)
                        }
                        break
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        guard !didAttemptRecovery, self.shouldRecoverFromServerError(error) else {
                            throw error
                        }

                        didAttemptRecovery = true
                        try await self.localServer.forceRestart()
                    }
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
        streamRequestIDs[conversationID] = requestID
    }

    private func consume(_ event: ResponsesAPIStreamEvent, conversationID: UUID) {
        guard let conversationIndex = indexForConversation(conversationID),
              let messageIndex = conversations[conversationIndex].messages.lastIndex(where: { $0.role == .assistant }) else { return }

        switch event {
        case .thoughtsDelta(let delta):
            let combined = (conversations[conversationIndex].messages[messageIndex].thoughts ?? "") + delta
            conversations[conversationIndex].messages[messageIndex].thoughts = normalizedThoughts(combined)
        case .outputDelta(let delta):
            conversations[conversationIndex].messages[messageIndex].content += delta
        case .completed(let finalText, let thoughts):
            if let finalText, finalText.count > conversations[conversationIndex].messages[messageIndex].content.count {
                conversations[conversationIndex].messages[messageIndex].content = finalText
            }
            if let thoughts {
                let normalizedThoughts = normalizedThoughts(thoughts)
                let currentThoughtCount = (conversations[conversationIndex].messages[messageIndex].thoughts ?? "").count
                if let normalizedThoughts, normalizedThoughts.count > currentThoughtCount {
                    conversations[conversationIndex].messages[messageIndex].thoughts = normalizedThoughts
                } else if normalizedThoughts == nil {
                    conversations[conversationIndex].messages[messageIndex].thoughts = nil
                }
            }
        }

        touchConversation(at: conversationIndex)
    }

    private func finishStreaming(in conversationID: UUID, preservePartialResult: Bool = false) {
        streamTasks[conversationID] = nil
        streamRequestIDs[conversationID] = nil

        guard let conversationIndex = indexForConversation(conversationID),
              let messageIndex = conversations[conversationIndex].messages.lastIndex(where: { $0.role == .assistant }) else {
            scheduleSave()
            return
        }

        let hasVisibleContent = conversations[conversationIndex].messages[messageIndex].hasVisibleContent
            || (conversations[conversationIndex].messages[messageIndex].thoughts ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

        if preservePartialResult || hasVisibleContent {
            conversations[conversationIndex].messages[messageIndex].state = .complete
        } else {
            conversations[conversationIndex].messages[messageIndex].state = .error
            conversations[conversationIndex].messages[messageIndex].errorText = Self.emptyResponseError
        }

        touchConversation(at: conversationIndex)
    }

    private func markAssistantError(_ message: String, in conversationID: UUID) {
        streamTasks[conversationID]?.cancel()
        streamTasks[conversationID] = nil
        streamRequestIDs[conversationID] = nil

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

            if !message.attachments.isEmpty {
                lines.append("### Attachments")
                lines.append("")

                for attachment in message.attachments {
                    lines.append("- \(attachment.displayTitle)")
                }

                lines.append("")

                for attachment in message.attachments {
                    lines.append("<details>")
                    lines.append("<summary>\(attachment.displayTitle)</summary>")
                    lines.append("")
                    lines.append(attachment.extractedText)
                    lines.append("")
                    lines.append("</details>")
                    lines.append("")
                }
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
        return cleaned.isEmpty ? "llocust Conversation" : cleaned
    }

    private func presentErrorMessage(_ message: String) {
        NSSound.beep()
        NSLog("llocust error: %@", message)
    }

    private func loadAttachments(from urls: [URL]) throws -> [ChatAttachment] {
        var attachments: [ChatAttachment] = []
        var usedCharacterCount = draftAttachments.reduce(0) { $0 + $1.characterCount }

        for url in urls {
            let attachment = try makeAttachment(from: url)

            guard usedCharacterCount + attachment.characterCount <= Self.maxDraftAttachmentCharacterCount else {
                throw AttachmentError.totalSizeExceeded(limit: Self.maxDraftAttachmentCharacterCount)
            }

            attachments.append(attachment)
            usedCharacterCount += attachment.characterCount
        }

        return attachments
    }

    private func makeAttachment(from url: URL) throws -> ChatAttachment {
        let resourceValues = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .isRegularFileKey, .nameKey])

        guard resourceValues.isRegularFile != false else {
            throw AttachmentError.unsupportedFile(url.lastPathComponent)
        }

        if let fileSize = resourceValues.fileSize, fileSize > Self.maxAttachmentFileSize {
            throw AttachmentError.fileTooLarge(url.lastPathComponent, limit: Self.maxAttachmentFileSize)
        }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let text = try decodeAttachmentText(data, fileName: resourceValues.name ?? url.lastPathComponent)
        let characterCount = text.count
        let extractedText: String
        let wasTruncated: Bool

        if characterCount > Self.maxAttachmentCharacterCount {
            extractedText = String(text.prefix(Self.maxAttachmentCharacterCount))
            wasTruncated = true
        } else {
            extractedText = text
            wasTruncated = false
        }

        return ChatAttachment(
            fileName: resourceValues.name ?? url.lastPathComponent,
            contentType: resourceValues.contentType?.preferredMIMEType ?? resourceValues.contentType?.identifier,
            extractedText: extractedText,
            characterCount: min(characterCount, Self.maxAttachmentCharacterCount),
            wasTruncated: wasTruncated
        )
    }

    private func decodeAttachmentText(_ data: Data, fileName: String) throws -> String {
        let encodings: [String.Encoding] = [
            .utf8,
            .utf16,
            .utf16LittleEndian,
            .utf16BigEndian,
            .ascii
        ]

        for encoding in encodings {
            if let text = String(data: data, encoding: encoding) {
                let trimmed = text.trimmingCharacters(in: .controlCharacters)
                if !trimmed.isEmpty {
                    return text
                }
            }
        }

        throw AttachmentError.unreadableText(fileName)
    }

    private func friendlyAttachmentErrorMessage(for error: Error) -> String {
        if let attachmentError = error as? AttachmentError {
            return attachmentError.localizedDescription
        }

        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }

        return "Couldn’t attach that file."
    }

    private func applyResolvedServerMetadata(_ metadata: ResponsesServerMetadata) {
        let models = metadata.models.isEmpty ? [AppSettings.fixedModelIdentifier] : metadata.models
        availableModels = models
        connectionState = .connected(models)
        settings.normalizeForSingleModel()

        let resolvedModel = resolvePreferredModel(from: models)
        if resolvedModel != settings.selectedModel {
            settings.registerModel(resolvedModel)
        }
    }

    private func resolvePreferredModel(from models: [String]) -> String {
        _ = models
        return AppSettings.fixedModelIdentifier
    }

    private func friendlyMessage(for error: Error, requestedBaseURL: String? = nil) -> String {
        if let localServerError = error as? LocalModelServerError {
            return localServerError.localizedDescription
        }

        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            if description.contains("Couldn’t connect"), let requestedBaseURL {
                return "\(description)\nTried: \(requestedBaseURL)"
            }
            return description
        }
        return error.localizedDescription
    }

    private func refreshServerMetadataNow() async {
        let baseURL = pinnedBaseURL
        let apiKey = settings.apiKey.nonEmpty

        do {
            try await localServer.ensureRunning()
            let metadata = try await client.resolveServerMetadata(preferredBaseURL: baseURL, apiKey: apiKey)
            applyResolvedServerMetadata(metadata)
        } catch {
            connectionState = .failed(friendlyMessage(for: error))
        }
    }

    private func normalizedThoughts(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func shouldRecoverFromServerError(_ error: Error) -> Bool {
        guard case let ResponsesAPIError.server(status, message) = error else {
            return false
        }

        guard status == 500 else {
            return false
        }

        let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedMessage.isEmpty || normalizedMessage == "internal server error"
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : self
    }
}

private enum AttachmentError: LocalizedError {
    case unsupportedFile(String)
    case unreadableText(String)
    case fileTooLarge(String, limit: Int)
    case totalSizeExceeded(limit: Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedFile(let fileName):
            return "Couldn’t attach \(fileName) because it isn’t a regular file."
        case .unreadableText(let fileName):
            return "Couldn’t read \(fileName). Attachments currently support UTF-8 or UTF-16 text files."
        case .fileTooLarge(let fileName, let limit):
            return "Couldn’t attach \(fileName) because it is larger than \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file))."
        case .totalSizeExceeded(let limit):
            return "These attachments are too large together. Keep the total attached text under roughly \(limit.formatted()) characters."
        }
    }
}

private actor LocalModelServer {
    private let session: URLSession
    private let fileManager = FileManager.default
    private let baseURL = URL(string: AppSettings.defaultBaseURL)!
    private let serverURL: URL
    private let workingDirectoryURL: URL
    private let pythonURL: URL
    private let checkpointURL: URL

    private var process: Process?
    private var outputPipe: Pipe?
    private var ownsProcess = false
    private var recentLogs = ""

    init(
        session: URLSession = .shared,
        sourceFilePath: String = #filePath
    ) {
        self.session = session
        self.serverURL = baseURL.appending(path: "responses")

        let sourceURL = URL(fileURLWithPath: sourceFilePath)
        let repositoryRoot = sourceURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        self.workingDirectoryURL = repositoryRoot.appending(path: "gpt-oss", directoryHint: .isDirectory)
        self.pythonURL = workingDirectoryURL.appending(path: ".venv/bin/python")
        self.checkpointURL = workingDirectoryURL.appending(path: "gpt-oss-20b/metal/metal/model.bin")
    }

    func ensureRunning() async throws {
        if await isReachable() {
            return
        }

        if let process, process.isRunning {
            try await waitUntilReachableOrExit(process)
            return
        }

        try validateRuntime()
        try startProcess()

        guard let process else {
            throw LocalModelServerError.startupFailed("The local server could not be launched.")
        }

        try await waitUntilReachableOrExit(process)
    }

    func stopIfNeeded() async {
        guard ownsProcess, let process, process.isRunning else { return }
        process.terminate()
    }

    func forceRestart() async throws {
        if ownsProcess, let process, process.isRunning {
            process.terminate()
        }

        handleProcessTermination()
        try terminateAnyServerListeningOnPort()
        try validateRuntime()
        try startProcess()

        guard let process else {
            throw LocalModelServerError.startupFailed("The local server could not be relaunched.")
        }

        try await waitUntilReachableOrExit(process)
    }

    private func validateRuntime() throws {
        guard fileManager.isExecutableFile(atPath: pythonURL.path) else {
            throw LocalModelServerError.missingPython(pythonURL.path)
        }

        guard fileManager.fileExists(atPath: checkpointURL.path) else {
            throw LocalModelServerError.missingCheckpoint(checkpointURL.path)
        }
    }

    private func startProcess() throws {
        let process = Process()
        let pipe = Pipe()

        recentLogs = ""
        ownsProcess = true

        process.executableURL = pythonURL
        process.currentDirectoryURL = workingDirectoryURL
        process.arguments = [
            "-m",
            "gpt_oss.responses_api.serve",
            "--checkpoint",
            checkpointURL.path,
            "--port",
            "\(baseURL.port ?? 8412)",
            "--inference-backend",
            "metal"
        ]

        var environment = ProcessInfo.processInfo.environment
        let strippedEnvironmentKeys = [
            "DYLD_INSERT_LIBRARIES",
            "__XPC_DYLD_INSERT_LIBRARIES",
            "__XCODE_BUILT_PRODUCTS_DIR_PATHS",
            "MTL_DEBUG_LAYER",
            "MTL_SHADER_VALIDATION",
            "METAL_DEVICE_WRAPPER_TYPE",
            "METAL_CAPTURE_ENABLED",
            "OS_ACTIVITY_DT_MODE"
        ]
        strippedEnvironmentKeys.forEach { environment.removeValue(forKey: $0) }
        environment["PYTHONUNBUFFERED"] = "1"
        environment["MTL_DEBUG_LAYER"] = "0"
        environment["MTL_SHADER_VALIDATION"] = "0"
        environment["METAL_DEVICE_WRAPPER_TYPE"] = "0"
        environment["METAL_CAPTURE_ENABLED"] = "0"
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            let chunk = String(decoding: data, as: UTF8.self)
            Task {
                await self.appendLogs(chunk)
            }
        }

        process.terminationHandler = { _ in
            Task {
                await self.handleProcessTermination()
            }
        }

        try process.run()
        self.process = process
        self.outputPipe = pipe
    }

    private func waitUntilReachableOrExit(_ launchedProcess: Process) async throws {
        let timeoutNanoseconds: UInt64 = 90_000_000_000
        let pollIntervalNanoseconds: UInt64 = 500_000_000
        var waitedNanoseconds: UInt64 = 0

        while waitedNanoseconds < timeoutNanoseconds {
            if await isReachable() {
                return
            }

            if !launchedProcess.isRunning {
                throw LocalModelServerError.startupFailed(recentLogSummary())
            }

            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            waitedNanoseconds += pollIntervalNanoseconds
        }

        throw LocalModelServerError.startupTimedOut(recentLogSummary())
    }

    private func isReachable() async -> Bool {
        var request = URLRequest(url: serverURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 2

        do {
            let (_, response) = try await session.data(for: request)
            return response is HTTPURLResponse
        } catch {
            return false
        }
    }

    private func appendLogs(_ chunk: String) {
        recentLogs += chunk

        let maxCharacters = 8_000
        if recentLogs.count > maxCharacters {
            recentLogs = String(recentLogs.suffix(maxCharacters))
        }
    }

    private func handleProcessTermination() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        process = nil
    }

    private func recentLogSummary() -> String? {
        let trimmed = recentLogs.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func terminateAnyServerListeningOnPort() throws {
        let lsof = Process()
        let outputPipe = Pipe()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = [
            "-tiTCP:\(baseURL.port ?? 8412)",
            "-sTCP:LISTEN"
        ]
        lsof.standardOutput = outputPipe
        lsof.standardError = Pipe()

        try lsof.run()
        lsof.waitUntilExit()

        guard lsof.terminationStatus == 0 else {
            return
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let processIDs = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0) }

        for processID in processIDs {
            kill(processID, SIGTERM)
        }

        if !processIDs.isEmpty {
            Thread.sleep(forTimeInterval: 0.5)
        }
    }
}

private enum LocalModelServerError: LocalizedError {
    case missingPython(String)
    case missingCheckpoint(String)
    case startupFailed(String?)
    case startupTimedOut(String?)

    var errorDescription: String? {
        switch self {
        case .missingPython(let path):
            return "The local metal runtime is missing its Python executable at \(path)."
        case .missingCheckpoint(let path):
            return "The local oss 20b Metal checkpoint is missing at \(path)."
        case .startupFailed(let logs):
            if let logs, !logs.isEmpty {
                return "The local oss 20b Metal server exited while starting.\n\n\(logs)"
            }
            return "The local oss 20b Metal server exited while starting."
        case .startupTimedOut(let logs):
            if let logs, !logs.isEmpty {
                return "The local oss 20b Metal server took too long to start.\n\n\(logs)"
            }
            return "The local oss 20b Metal server took too long to start."
        }
    }
}
