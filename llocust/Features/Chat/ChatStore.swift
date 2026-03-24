import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class ChatStore: ObservableObject {
    private static let emptyResponseError = "The model finished without returning an answer. Try regenerating, lowering reasoning effort, or checking the local server logs."
    private static let maxAttachmentFileSize = 1_000_000
    private static let maxAttachmentCharacterCount = 120_000
    private static let maxDraftAttachmentCharacterCount = 360_000
    private static let compactionSummaryCharacterLimit = 10_000
    private static let compactionRequestMessageBudget = 24_000
    private static let compactionRequestOutputTokens = 900
    private static let minimumMessagesToCompact = 1
    private static let minimumRecentMessagesToKeep = 2

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
    @Published private(set) var isLaunchReady = false
    @Published private(set) var launchErrorMessage: String?
    @Published private(set) var contextCompactionStatus: [UUID: String] = [:]
    @Published var settings: AppSettings {
        didSet {
            persistSettings()
        }
    }

    private let persistence = ChatPersistence()
    private let client = ResponsesAPIClient()
    private let localServer = LocalModelServer()
    private let weatherService = WeatherService()
    private let userDefaults = UserDefaults.standard
    private let settingsKey = "llocust.Settings"

    private var saveTask: Task<Void, Never>?
    private var streamTasks: [UUID: Task<Void, Never>] = [:]
    private var streamRequestIDs: [UUID: String] = [:]
    private var rawOutputBuffers: [UUID: String] = [:]
    private var rawThoughtBuffers: [UUID: String] = [:]
    private var launchPreparationTask: Task<Void, Never>?
    private var postLaunchWarmupTask: Task<Void, Never>?
    private var launchPreparationGeneration: Int = 0
    private var warmedLaunchModels: Set<String> = []
    private var didLoadPersistedState = false
    private var didPrepareLaunchModel = false
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

        settings.normalize()
        persistSettings()
        startLaunchPreparationIfNeeded(forceRestart: true)
        weatherService.start()

        Task {
            await loadPersistedState()
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

    var modelPickerOptions: [String] {
        AppSettings.modelPickerOptions()
    }

    func contextCompactionMessage(for conversationID: UUID?) -> String? {
        guard let conversationID else { return nil }
        return contextCompactionStatus[conversationID]
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

        didLoadPersistedState = true
        updateLaunchReadiness()
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
        guard let conversationID = selectedConversation?.id ?? selectedConversationID else { return }
        cancelGeneration(for: conversationID)
    }

    func cancelGeneration(for conversationID: UUID, sendRemoteCancel: Bool = true) {
        let requestID = streamRequestIDs[conversationID]
        let apiKey = settings.apiKey.nonEmpty
        let baseURL = pinnedBaseURL

        streamTasks[conversationID]?.cancel()
        streamTasks[conversationID] = nil
        streamRequestIDs[conversationID] = nil
        clearRawStreamingBuffers(for: conversationID)

        guard let conversationIndex = indexForConversation(conversationID),
              let assistantIndex = conversations[conversationIndex].messages.lastIndex(where: { $0.role == .assistant && $0.state == .streaming }) else {
            scheduleSave()
            if sendRemoteCancel, let requestID {
                Task { [client] in
                    try? await client.cancelResponses(baseURL: baseURL, apiKey: apiKey, requestIDs: [requestID])
                }
            }
            return
        }

        if conversations[conversationIndex].messages[assistantIndex].trimmedContent.isEmpty,
           conversations[conversationIndex].messages[assistantIndex].attachments.isEmpty,
           (conversations[conversationIndex].messages[assistantIndex].thoughts ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            conversations[conversationIndex].messages.remove(at: assistantIndex)
        } else {
            conversations[conversationIndex].messages[assistantIndex].state = .complete
            conversations[conversationIndex].messages[assistantIndex].isThoughtsStreaming = false
        }

        touchConversation(at: conversationIndex)

        guard sendRemoteCancel, let requestID else { return }

        Task { [client] in
            try? await client.cancelResponses(baseURL: baseURL, apiKey: apiKey, requestIDs: [requestID])
        }
    }

    func stopAllModelActivity() {
        let requestIDs = Array(streamRequestIDs.values)
        let conversationIDs = Array(streamTasks.keys)
        let apiKey = settings.apiKey.nonEmpty
        let baseURL = pinnedBaseURL

        conversationIDs.forEach { cancelGeneration(for: $0, sendRemoteCancel: false) }

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
        _ = model
        settings.normalize(availableModels: modelPickerOptions)
    }

    func applyDefaultModel(_ model: String) {
        _ = model
        settings.normalize(availableModels: modelPickerOptions)
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
        settings.normalize(availableModels: modelPickerOptions)
        connectionState = .checking

        startLaunchPreparationIfNeeded(forceRestart: true)
    }

    func retryLaunchPreparation() {
        launchErrorMessage = nil
        isLaunchReady = false

        Task { [weak self] in
            await self?.refreshServerMetadataNow()
        }
    }

    private func requestAssistantReply(for conversationID: UUID) {
        guard streamTasks[conversationID] == nil,
              let conversationIndex = indexForConversation(conversationID) else { return }

        settings.normalize(availableModels: modelPickerOptions)
        let responseMode = settings.selectedResponseMode

        let assistantMessage = ChatMessage(
            role: .assistant,
            content: "",
            thoughts: nil,
            isThoughtsStreaming: true,
            state: .streaming
        )
        conversations[conversationIndex].messages.append(assistantMessage)
        rawOutputBuffers[conversationID] = ""
        rawThoughtBuffers[conversationID] = ""
        touchConversation(at: conversationIndex)

        let task = Task { [weak self] in
            guard let self else { return }
            let requestedBaseURL = AppSettings.defaultBaseURL

            do {
                self.postLaunchWarmupTask?.cancel()
                self.postLaunchWarmupTask = nil

                if let launchPreparationTask = self.launchPreparationTask {
                    await launchPreparationTask.value
                }

                var didAttemptEnsureRunning = false
                var didAttemptRecovery = false
                var didAttemptFalseRefusalRecovery = false

                while true {
                    try Task.checkCancellation()
                    let plan = try self.makeAssistantReplyPlan(for: conversationID)

                    do {
                        self.clearContextCompactionStatus(for: conversationID)
                        if responseMode == .chat {
                            try await self.streamPrimaryResponse(
                                for: conversationID,
                                request: plan.request
                            )
                        } else {
                            try await self.completeReviewedResponse(
                                for: conversationID,
                                plan: plan,
                                responseMode: responseMode
                            )
                        }

                        if !didAttemptFalseRefusalRecovery,
                           let retryRequest = self.makeFalseRefusalRecoveryRequestIfNeeded(
                            for: conversationID,
                            baseRequest: plan.request
                           ) {
                            didAttemptFalseRefusalRecovery = true
                            self.resetAssistantStreamingMessage(in: conversationID)

                            if responseMode == .chat {
                                try await self.streamPrimaryResponse(
                                    for: conversationID,
                                    request: retryRequest
                                )
                            } else {
                                try await self.completeReviewedResponse(
                                    for: conversationID,
                                    plan: AssistantReplyPlan(
                                        preparedContext: plan.preparedContext,
                                        request: retryRequest
                                    ),
                                    responseMode: responseMode
                                )
                            }
                        }

                        break
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        self.streamRequestIDs[conversationID] = nil

                        if try await self.compactConversationContextIfNeeded(
                            for: conversationID,
                            triggeredBy: error
                        ) {
                            didAttemptEnsureRunning = false
                            didAttemptRecovery = false
                            continue
                        }

                        if !didAttemptEnsureRunning,
                           self.usesResponsesServerForDefaultModel,
                           self.shouldRetryAfterEnsuringServer(error) {
                            didAttemptEnsureRunning = true
                            self.connectionState = .checking
                            try await self.localServer.ensureRunning(modelReference: self.resolvedDefaultModel)
                            await self.reloadAvailableModels()
                            continue
                        }

                        guard !didAttemptRecovery,
                              self.usesResponsesServerForDefaultModel,
                              self.shouldRecoverFromServerError(error) else {
                            throw error
                        }

                        didAttemptRecovery = true
                        self.connectionState = .checking
                        try await self.localServer.forceRestart(modelReference: self.resolvedDefaultModel)
                        await self.reloadAvailableModels()
                    }
                }

                self.clearContextCompactionStatus(for: conversationID)
                self.finishStreaming(in: conversationID)
            } catch is CancellationError {
                self.clearContextCompactionStatus(for: conversationID)
                self.finishStreaming(in: conversationID, preservePartialResult: true)
            } catch {
                self.clearContextCompactionStatus(for: conversationID)
                let message = self.friendlyMessage(for: error, requestedBaseURL: requestedBaseURL)
                self.markAssistantError(message, in: conversationID)
                self.connectionState = .failed(message)
            }
        }

        streamTasks[conversationID] = task
    }

    private func makeAssistantReplyPlan(for conversationID: UUID) throws -> AssistantReplyPlan {
        guard let conversationIndex = indexForConversation(conversationID) else {
            throw ResponsesAPIError.serverUnavailable("This conversation is no longer available.")
        }

        let conversation = conversations[conversationIndex]
        let history = conversation.messages.dropLast().filter { $0.hasVisibleContent }
        let preparedContext = preparedConversationContext(
            from: Array(history),
            conversation: conversation
        )
        let samplingProfile = samplingProfile(for: preparedContext.messages)

        return AssistantReplyPlan(
            preparedContext: preparedContext,
            request: ResponsesAPIRequest(
                requestID: UUID().uuidString,
                baseURL: pinnedBaseURL,
                apiKey: settings.apiKey.nonEmpty,
                model: resolvedDefaultModel,
                reasoningEffort: settings.selectedReasoningEffort,
                temperature: samplingProfile.temperature,
                repeatPenalty: settings.repeatPenalty,
                topP: samplingProfile.topP,
                maxOutputTokens: nil,
                instructions: assistantInstructions(
                    baseInstructions: preparedContext.instructions,
                    model: resolvedDefaultModel
                ),
                messages: preparedContext.messages,
                tools: availableTools(for: resolvedDefaultModel)
            )
        )
    }

    private func streamPrimaryResponse(
        for conversationID: UUID,
        request: ResponsesAPIRequest
    ) async throws {
        if request.tools.isEmpty {
            streamRequestIDs[conversationID] = AppSettings.usesResponsesServer(request.model) ? request.requestID : nil
            let stream = client.streamResponse(for: request)
            for try await event in stream {
                try Task.checkCancellation()
                consume(event, conversationID: conversationID)
            }
            return
        }

        var toolInputItems = request.inputItems
        var activeRequest = request
        let maxToolRounds = 4

        for round in 0..<maxToolRounds {
            streamRequestIDs[conversationID] = AppSettings.usesResponsesServer(activeRequest.model) ? activeRequest.requestID : nil
            let stream = client.streamResponse(for: activeRequest)
            var finalPayload: ParsedResponsePayload?

            for try await event in stream {
                try Task.checkCancellation()
                consume(event, conversationID: conversationID)

                if case .completed(let payload) = event {
                    finalPayload = payload
                }
            }

            guard let payload = finalPayload else {
                return
            }

            guard !payload.toolCalls.isEmpty else {
                return
            }

            toolInputItems.append(contentsOf: payload.outputItems)
            toolInputItems.append(contentsOf: await toolOutputItems(for: payload.toolCalls))

            if round < maxToolRounds - 1 {
                resetAssistantStreamingMessage(in: conversationID)
            }

            activeRequest = request.replacing(
                requestID: UUID().uuidString,
                inputItems: toolInputItems
            )
        }

        throw ResponsesAPIError.serverUnavailable("The model kept requesting tools without returning a final answer.")
    }

    private func completeReviewedResponse(
        for conversationID: UUID,
        plan: AssistantReplyPlan,
        responseMode: AssistantResponseMode
    ) async throws {
        guard let reviewerModel = responseMode.reviewerModelIdentifier else {
            throw ResponsesAPIError.serverUnavailable("No reviewer model was configured for this mode.")
        }

        var transcript = ReviewedThoughtTranscript(
            primaryModelDisplayName: AppSettings.displayName(for: plan.request.model),
            reviewerModelDisplayName: AppSettings.displayName(for: reviewerModel)
        )

        let primaryStage = try await streamReviewedStage(
            for: conversationID,
            request: plan.request,
            stage: .primary,
            transcript: transcript
        )
        transcript = primaryStage.transcript
        let primaryResponse = primaryStage.payload
        try Task.checkCancellation()

        let reviewerRequest = makeReviewerRequest(
            preparedContext: plan.preparedContext,
            primaryResponse: primaryResponse,
            reviewerModel: reviewerModel
        )
        let reviewerStage = try await streamReviewedStage(
            for: conversationID,
            request: reviewerRequest,
            stage: .reviewer,
            transcript: transcript
        )
        transcript = reviewerStage.transcript
        try Task.checkCancellation()

        applyReviewedTranscript(
            transcript,
            visibleContent: reviewerStage.payload.outputText,
            isStreaming: true,
            in: conversationID
        )
    }

    private func streamReviewedStage(
        for conversationID: UUID,
        request: ResponsesAPIRequest,
        stage: ReviewedStreamStage,
        transcript initialTranscript: ReviewedThoughtTranscript
    ) async throws -> ReviewedStageResult {
        var transcript = initialTranscript

        if !request.tools.isEmpty {
            var toolInputItems = request.inputItems
            var activeRequest = request
            let maxToolRounds = 4

            for round in 0..<maxToolRounds {
                streamRequestIDs[conversationID] = AppSettings.usesResponsesServer(activeRequest.model) ? activeRequest.requestID : nil

                let stream = client.streamResponse(for: activeRequest)
                var finalPayload: ParsedResponsePayload?
                for try await event in stream {
                    try Task.checkCancellation()
                    transcript.apply(event, to: stage)

                    let visibleContent: String?
                    switch stage {
                    case .primary:
                        visibleContent = nil
                    case .reviewer:
                        visibleContent = transcript.payload(for: .reviewer).outputText
                    }

                    applyReviewedTranscript(
                        transcript,
                        visibleContent: visibleContent,
                        isStreaming: true,
                        in: conversationID
                    )

                    if case .completed(let payload) = event {
                        finalPayload = payload
                    }
                }

                guard let payload = finalPayload else {
                    return ReviewedStageResult(
                        transcript: transcript,
                        payload: transcript.payload(for: stage)
                    )
                }

                guard !payload.toolCalls.isEmpty else {
                    return ReviewedStageResult(
                        transcript: transcript,
                        payload: payload
                    )
                }

                toolInputItems.append(contentsOf: payload.outputItems)
                toolInputItems.append(contentsOf: await toolOutputItems(for: payload.toolCalls))

                if round < maxToolRounds - 1 {
                    transcript.reset(stage: stage)
                }

                activeRequest = request.replacing(
                    requestID: UUID().uuidString,
                    inputItems: toolInputItems
                )
            }

            throw ResponsesAPIError.serverUnavailable("The model kept requesting tools without returning a final answer.")
        }

        streamRequestIDs[conversationID] = AppSettings.usesResponsesServer(request.model) ? request.requestID : nil

        let stream = client.streamResponse(for: request)
        for try await event in stream {
            try Task.checkCancellation()
            transcript.apply(event, to: stage)

            let visibleContent: String?
            switch stage {
            case .primary:
                visibleContent = nil
            case .reviewer:
                visibleContent = transcript.payload(for: .reviewer).outputText
            }

            applyReviewedTranscript(
                transcript,
                visibleContent: visibleContent,
                isStreaming: true,
                in: conversationID
            )
        }

        return ReviewedStageResult(
            transcript: transcript,
            payload: transcript.payload(for: stage)
        )
    }

    private func makeReviewerRequest(
        preparedContext: PreparedConversationContext,
        primaryResponse: ParsedResponsePayload,
        reviewerModel: String
    ) -> ResponsesAPIRequest {
        let reviewPrompt = """
Review the assistant draft above before it goes to the user.

First decide whether the draft needs any factual or operational improvement at all.
If it is already correct, workable, and helpful enough, return it unchanged immediately.

If changes are needed, make the smallest possible edits needed to fix:
- factual mistakes
- code, commands, or steps that would not work
- unsupported claims
- missing details that would otherwise make the answer fail

Keep the wording, tone, structure, and personality as close to the draft as possible.
Do not rewrite just to improve style or to sound more like you.
Return only the final answer for the user.
"""

        return ResponsesAPIRequest(
            requestID: UUID().uuidString,
            baseURL: pinnedBaseURL,
            apiKey: settings.apiKey.nonEmpty,
            model: reviewerModel,
            reasoningEffort: .medium,
            temperature: 0.12,
            repeatPenalty: 0.25,
            topP: 0.8,
            maxOutputTokens: nil,
            instructions: reviewerInstructions(
                baseInstructions: preparedContext.instructions
            ),
            messages: preparedContext.messages + [
                ChatMessage(role: .assistant, content: primaryResponse.outputText),
                ChatMessage(role: .user, content: reviewPrompt)
            ]
        )
    }

    private func reviewerInstructions(baseInstructions: String) -> String {
        [
            baseInstructions,
            """
You are checking and minimally revising a draft reply from another model before it reaches the user.
Your job is verification, not restyling.
Preserve the draft whenever possible.
If the draft is already factually sound, operationally correct, and helpful enough, return it unchanged.
When a correction is necessary, keep the edit as small as possible and preserve the original wording, tone, structure, and personality.
Focus on factual accuracy, whether code or steps would actually work, unsupported claims, and missing details that would otherwise cause failure.
Think in a short, disciplined way: check the draft once, decide quickly whether any fix is actually needed, then either keep it or make the smallest necessary correction.
Do not repeatedly restate the task, re-read the prompt, compare multiple rewrites, or narrate uncertainty after you already have a sufficient answer.
If there is no concrete factual or operational problem to fix, stop and return the draft as-is.
Do not add your own personality, do not make the response chattier or sharper, and do not mention the review process.
"""
        ]
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .joined(separator: "\n\n")
    }

    private func compactConversationContextIfNeeded(
        for conversationID: UUID,
        triggeredBy error: Error
    ) async throws -> Bool {
        guard shouldCompactContext(for: error), settings.usesConversationMemory else {
            return false
        }

        var characterBudget = Self.compactionRequestMessageBudget

        while characterBudget >= 4_000 {
            try Task.checkCancellation()

            guard let plan = makeCompactionPlan(
                for: conversationID,
                characterBudget: characterBudget
            ) else {
                clearContextCompactionStatus(for: conversationID)
                return false
            }

            setContextCompactionStatus(
                "Compacting older context to keep this conversation going…",
                for: conversationID
            )

            do {
                let response = try await client.completeResponse(for: plan.request)
                try Task.checkCancellation()

                guard let summary = normalizedCompactionSummary(response.outputText) else {
                    throw ResponsesAPIError.serverUnavailable("The context compactor returned an empty summary.")
                }

                applyCompactionSummary(
                    summary,
                    compactedMessageCount: plan.compactedMessageCount,
                    to: conversationID
                )

                clearContextCompactionStatus(for: conversationID)
                return true
            } catch is CancellationError {
                clearContextCompactionStatus(for: conversationID)
                throw CancellationError()
            } catch let compactionError {
                if shouldCompactContext(for: compactionError) {
                    characterBudget /= 2
                    continue
                }

                clearContextCompactionStatus(for: conversationID)
                throw compactionError
            }
        }

        clearContextCompactionStatus(for: conversationID)
        return false
    }

    private func makeCompactionPlan(
        for conversationID: UUID,
        characterBudget: Int
    ) -> ConversationCompactionPlan? {
        guard let conversationIndex = indexForConversation(conversationID) else {
            return nil
        }

        let conversation = conversations[conversationIndex]
        let history = conversation.messages.filter { $0.hasVisibleContent }
        let digest = effectiveMemoryDigest(for: conversation, historyCount: history.count)
        let compactedCount = digest?.compactedMessageCount ?? 0
        let remainingMessages = Array(history.dropFirst(compactedCount))
        let preferredKeepRecentCount = min(max(settings.recentContextMessageCount, 4), 20)
        let keepRecentCount = min(
            preferredKeepRecentCount,
            max(Self.minimumRecentMessagesToKeep, remainingMessages.count - 1)
        )

        guard remainingMessages.count > keepRecentCount else {
            return nil
        }

        let compactableMessages = Array(remainingMessages.dropLast(keepRecentCount))
        guard !compactableMessages.isEmpty else {
            return nil
        }

        var chunk: [ChatMessage] = []
        var usedCharacters = 0

        for message in compactableMessages {
            let messageCost = max(message.approximateModelInputCharacterCount, 1)
            if !chunk.isEmpty, usedCharacters + messageCost > characterBudget {
                break
            }

            chunk.append(message)
            usedCharacters += messageCost
        }

        if chunk.count < Self.minimumMessagesToCompact {
            chunk = Array(compactableMessages.prefix(Self.minimumMessagesToCompact))
        }

        guard !chunk.isEmpty else {
            return nil
        }

        let transcript = renderCompactionTranscript(chunk)
        let existingSummary = digest?.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingMemorySection: String
        if let existingSummary, !existingSummary.isEmpty {
            existingMemorySection = "Existing rolling memory:\n\(existingSummary)"
        } else {
            existingMemorySection = "Existing rolling memory: (none yet)"
        }
        let userPrompt = [
            "Update the rolling memory for this conversation so future replies can continue with a fresh context window.",
            existingMemorySection,
            "New transcript slice to fold in:\n\(transcript)"
        ].joined(separator: "\n\n")

        let request = ResponsesAPIRequest(
            requestID: UUID().uuidString,
            baseURL: pinnedBaseURL,
            apiKey: settings.apiKey.nonEmpty,
            model: resolvedDefaultModel,
            reasoningEffort: .low,
            temperature: 0.35,
            repeatPenalty: 0.1,
            topP: 0.9,
            maxOutputTokens: Self.compactionRequestOutputTokens,
            instructions: compactionInstructions,
            messages: [ChatMessage(role: .user, content: userPrompt)]
        )

        return ConversationCompactionPlan(
            request: request,
            compactedMessageCount: compactedCount + chunk.count
        )
    }

    private func renderCompactionTranscript(_ messages: [ChatMessage]) -> String {
        messages.enumerated().map { index, message in
            var sections: [String] = ["\(index + 1). \(message.role == .user ? "User" : "Assistant")"]

            if !message.trimmedContent.isEmpty {
                sections.append(message.content)
            }

            if !message.attachments.isEmpty {
                sections.append(contentsOf: message.attachments.map(\.modelInputText))
            }

            return sections.joined(separator: "\n")
        }
        .joined(separator: "\n\n---\n\n")
    }

    private func normalizedCompactionSummary(_ text: String) -> String? {
        let normalized = ModelOutputSanitizer.sanitize(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else {
            return nil
        }

        return normalized.truncated(to: Self.compactionSummaryCharacterLimit)
    }

    private func applyCompactionSummary(
        _ summary: String,
        compactedMessageCount: Int,
        to conversationID: UUID
    ) {
        guard let conversationIndex = indexForConversation(conversationID) else { return }

        conversations[conversationIndex].memoryDigest = ConversationMemoryDigest(
            summary: summary,
            compactedMessageCount: compactedMessageCount,
            updatedAt: Date()
        )
        touchConversation(at: conversationIndex)
    }

    private func setContextCompactionStatus(_ message: String, for conversationID: UUID) {
        contextCompactionStatus[conversationID] = message
    }

    private func clearContextCompactionStatus(for conversationID: UUID) {
        contextCompactionStatus[conversationID] = nil
    }

    private func shouldCompactContext(for error: Error) -> Bool {
        guard case let ResponsesAPIError.server(status, message) = error else {
            return false
        }

        guard status == 400 else {
            return false
        }

        return message.localizedCaseInsensitiveContains("input is too long for the local model")
            || message.localizedCaseInsensitiveContains("context window")
            || message.localizedCaseInsensitiveContains("too long")
    }

    private func consume(_ event: ResponsesAPIStreamEvent, conversationID: UUID) {
        guard let conversationIndex = indexForConversation(conversationID),
              let messageIndex = conversations[conversationIndex].messages.lastIndex(where: { $0.role == .assistant }) else { return }

        switch event {
        case .thoughtsDelta(let delta):
            let combined = (rawThoughtBuffers[conversationID] ?? conversations[conversationIndex].messages[messageIndex].thoughts ?? "") + delta
            rawThoughtBuffers[conversationID] = combined
            conversations[conversationIndex].messages[messageIndex].thoughts = normalizedThoughts(
                ModelOutputSanitizer.sanitize(combined)
            )
            conversations[conversationIndex].messages[messageIndex].isThoughtsStreaming = true
        case .outputDelta(let delta):
            let combined = (rawOutputBuffers[conversationID] ?? conversations[conversationIndex].messages[messageIndex].content) + delta
            rawOutputBuffers[conversationID] = combined
            conversations[conversationIndex].messages[messageIndex].content = ModelOutputSanitizer.sanitize(combined)
            conversations[conversationIndex].messages[messageIndex].isThoughtsStreaming = false
        case .completed(let payload):
            if let finalText = payload.outputText.nonEmpty {
                rawOutputBuffers[conversationID] = finalText
                conversations[conversationIndex].messages[messageIndex].content = ModelOutputSanitizer.sanitize(finalText)
            }
            if let thoughts = payload.thoughts {
                rawThoughtBuffers[conversationID] = thoughts
                let normalizedThoughts = normalizedThoughts(ModelOutputSanitizer.sanitize(thoughts))
                let currentThoughtCount = (conversations[conversationIndex].messages[messageIndex].thoughts ?? "").count
                if let normalizedThoughts, normalizedThoughts.count >= currentThoughtCount {
                    conversations[conversationIndex].messages[messageIndex].thoughts = normalizedThoughts
                } else if normalizedThoughts == nil {
                    conversations[conversationIndex].messages[messageIndex].thoughts = nil
                }

                conversations[conversationIndex].messages[messageIndex].isThoughtsStreaming = false
            } else if payload.outputText.nonEmpty != nil {
                conversations[conversationIndex].messages[messageIndex].isThoughtsStreaming = false
            }
        }

        touchConversation(at: conversationIndex)
    }

    private func finishStreaming(in conversationID: UUID, preservePartialResult: Bool = false) {
        streamTasks[conversationID] = nil
        streamRequestIDs[conversationID] = nil
        clearRawStreamingBuffers(for: conversationID)

        guard let conversationIndex = indexForConversation(conversationID),
              let messageIndex = conversations[conversationIndex].messages.lastIndex(where: { $0.role == .assistant && $0.state == .streaming }) else {
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
        conversations[conversationIndex].messages[messageIndex].isThoughtsStreaming = false

        touchConversation(at: conversationIndex)
    }

    private func markAssistantError(_ message: String, in conversationID: UUID) {
        streamTasks[conversationID]?.cancel()
        streamTasks[conversationID] = nil
        streamRequestIDs[conversationID] = nil
        clearRawStreamingBuffers(for: conversationID)

        guard let conversationIndex = indexForConversation(conversationID),
              let assistantIndex = conversations[conversationIndex].messages.lastIndex(where: { $0.role == .assistant && $0.state == .streaming }) else {
            presentErrorMessage(message)
            return
        }

        conversations[conversationIndex].messages[assistantIndex].state = .error
        conversations[conversationIndex].messages[assistantIndex].isThoughtsStreaming = false
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

    private func clearRawStreamingBuffers(for conversationID: UUID) {
        rawOutputBuffers[conversationID] = nil
        rawThoughtBuffers[conversationID] = nil
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
        objectWillChange.send()
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

        if let memoryDigest = conversation.memoryDigest,
           !memoryDigest.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("## Rolling Memory")
            lines.append("")
            lines.append(memoryDigest.summary)
            lines.append("")
        }

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
        let models = AppSettings.normalizedModelList(metadata.models)
        let fallbackModels = models.isEmpty ? AppSettings.supportedModelIdentifiers : AppSettings.normalizedModelList(models + AppSettings.supportedModelIdentifiers)

        settings.normalize(availableModels: fallbackModels)
        availableModels = fallbackModels
        connectionState = .connected(fallbackModels)
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
        startLaunchPreparationIfNeeded(forceRestart: true)
        await launchPreparationTask?.value
    }

    private var resolvedDefaultModel: String {
        AppSettings.canonicalModelIdentifier(settings.defaultModel)
    }

    private var usesDirectOllamaForDefaultModel: Bool {
        AppSettings.usesDirectOllamaAPI(resolvedDefaultModel)
    }

    private var usesResponsesServerForDefaultModel: Bool {
        AppSettings.usesResponsesServer(resolvedDefaultModel)
    }

    private func reloadAvailableModels() async {
        do {
            let metadata = try await client.resolveServerMetadata(
                preferredBaseURL: pinnedBaseURL,
                apiKey: settings.apiKey.nonEmpty
            )
            applyResolvedServerMetadata(metadata)
        } catch {
            applyResolvedServerMetadata(
                ResponsesServerMetadata(baseURL: pinnedBaseURL, models: [resolvedDefaultModel])
            )
        }
    }

    private func applyReviewedTranscript(
        _ transcript: ReviewedThoughtTranscript,
        visibleContent: String?,
        isStreaming: Bool,
        in conversationID: UUID
    ) {
        guard let conversationIndex = indexForConversation(conversationID),
              let messageIndex = conversations[conversationIndex].messages.lastIndex(where: { $0.role == .assistant && $0.state == .streaming }) else {
            return
        }

        let normalizedVisibleContent = visibleContent.map(ModelOutputSanitizer.sanitize) ?? ""
        let normalizedThoughts = transcript.markdown.flatMap(normalizedThoughts)

        conversations[conversationIndex].messages[messageIndex].content = normalizedVisibleContent
        conversations[conversationIndex].messages[messageIndex].thoughts = normalizedThoughts
        conversations[conversationIndex].messages[messageIndex].isThoughtsStreaming = isStreaming
        rawOutputBuffers[conversationID] = normalizedVisibleContent.isEmpty ? nil : normalizedVisibleContent
        rawThoughtBuffers[conversationID] = normalizedThoughts
        touchConversation(at: conversationIndex)
    }

    private func normalizedThoughts(_ text: String) -> String? {
        let trimmed = ModelOutputSanitizer.sanitizeThoughts(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func makeFalseRefusalRecoveryRequestIfNeeded(
        for conversationID: UUID,
        baseRequest: ResponsesAPIRequest
    ) -> ResponsesAPIRequest? {
        guard let conversationIndex = indexForConversation(conversationID) else {
            return nil
        }

        guard let lastUserPrompt = conversations[conversationIndex].messages.last(where: { $0.role == .user })?.trimmedContent,
              isLikelyBenignWellnessRequest(lastUserPrompt),
              let assistantText = conversations[conversationIndex].messages.last(where: { $0.role == .assistant })?.trimmedContent,
              isLikelyGenericRefusal(assistantText) else {
            return nil
        }

        let instructions = [
            baseRequest.instructions?.trimmingCharacters(in: .whitespacesAndNewlines),
            """
The previous draft appears to have incorrectly refused a benign wellness request.
If the user is asking for practical help with quitting smoking or vaping, answer directly with a useful plan instead of refusing.
Do not mention policy, moderation, or whether the request is allowed.
"""
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")

        return ResponsesAPIRequest(
            requestID: UUID().uuidString,
            baseURL: baseRequest.baseURL,
            apiKey: baseRequest.apiKey,
            model: baseRequest.model,
            reasoningEffort: .medium,
            temperature: min(baseRequest.temperature, 0.78),
            repeatPenalty: baseRequest.repeatPenalty,
            topP: min(baseRequest.topP, 0.92),
            maxOutputTokens: baseRequest.maxOutputTokens,
            instructions: instructions,
            messages: baseRequest.messages,
            inputItems: baseRequest.inputItems,
            tools: baseRequest.tools
        )
    }

    private func isLikelyGenericRefusal(_ text: String) -> Bool {
        let normalized = text
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard normalized.count <= 220 else {
            return false
        }

        let refusalPhrases = [
            "i'm sorry, but i can't help with that",
            "i can't help with that",
            "i cant help with that",
            "i can't assist with that",
            "i cant assist with that",
            "i can't provide that",
            "i cant provide that"
        ]

        return refusalPhrases.contains(where: normalized.contains)
    }

    private func isLikelyBenignWellnessRequest(_ text: String) -> Bool {
        let normalized = text
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")

        let benignSignals = [
            "stop smoking",
            "quit smoking",
            "smoking cessation",
            "stop vaping",
            "quit vaping",
            "quit nicotine",
            "nicotine plan",
            "how to stop smoking",
            "how do i stop smoking"
        ]

        let dangerousSignals = [
            "kill",
            "suicide",
            "self-harm",
            "hurt myself",
            "weapon",
            "bomb",
            "hack",
            "poison"
        ]

        return benignSignals.contains(where: normalized.contains)
            && !dangerousSignals.contains(where: normalized.contains)
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

    private func shouldRetryAfterEnsuringServer(_ error: Error) -> Bool {
        if case ResponsesAPIError.serverUnavailable = error {
            return true
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet, .timedOut:
                return true
            default:
                return false
            }
        }

        return false
    }

    private func startLaunchPreparationIfNeeded(forceRestart: Bool = false) {
        if forceRestart {
            launchPreparationTask?.cancel()
            launchPreparationTask = nil
            postLaunchWarmupTask?.cancel()
            postLaunchWarmupTask = nil
            warmedLaunchModels.removeAll()
            didPrepareLaunchModel = false
        }

        guard launchPreparationTask == nil else { return }
        connectionState = .checking
        launchErrorMessage = nil

        let modelReference = resolvedDefaultModel
        let criticalLaunchModels = launchPreparationModels
        launchPreparationGeneration += 1
        let generation = launchPreparationGeneration
        launchPreparationTask = Task { [weak self] in
            guard let self else { return }

            defer {
                if self.launchPreparationGeneration == generation {
                    self.launchPreparationTask = nil
                }
            }

            do {
                var didAttemptRecovery = false

                while true {
                    do {
                        if self.usesResponsesServerForDefaultModel {
                            if forceRestart {
                                try await self.localServer.forceRestart(modelReference: modelReference)
                            } else {
                                try await self.localServer.ensureRunning(modelReference: modelReference)
                            }
                        } else if self.usesDirectOllamaForDefaultModel {
                            await self.localServer.stopIfNeeded()
                        }

                        try await self.prewarmLaunchModels(criticalLaunchModels)
                        self.markLaunchPreparationReady()
                        self.startPostLaunchMetadataRefresh(generation: generation)
                        break
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        guard self.usesResponsesServerForDefaultModel,
                              !didAttemptRecovery,
                              self.shouldRecoverFromServerError(error) || self.shouldRetryAfterEnsuringServer(error) else {
                            throw error
                        }

                        didAttemptRecovery = true
                        try await self.localServer.forceRestart(modelReference: modelReference)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                let message = self.friendlyMessage(for: error)
                self.didPrepareLaunchModel = false
                self.isLaunchReady = false
                self.connectionState = .failed(message)
                self.launchErrorMessage = message
            }
        }
    }

    private func updateLaunchReadiness() {
        guard didLoadPersistedState, didPrepareLaunchModel else { return }
        isLaunchReady = true
    }

    private var launchPreparationModels: [String] {
        AppSettings.normalizedModelList([resolvedDefaultModel])
    }

    private func markLaunchPreparationReady() {
        let fallbackModels = availableModels.isEmpty
            ? AppSettings.supportedModelIdentifiers
            : availableModels

        availableModels = fallbackModels
        connectionState = .connected(fallbackModels)
        didPrepareLaunchModel = true
        updateLaunchReadiness()
    }

    private func startPostLaunchMetadataRefresh(generation: Int) {
        postLaunchWarmupTask?.cancel()
        postLaunchWarmupTask = Task { [weak self] in
            guard let self else { return }

            await self.reloadAvailableModels()

            if self.launchPreparationGeneration == generation {
                self.postLaunchWarmupTask = nil
            }
        }
    }

    private var compactionInstructions: String {
        """
You are compacting a long-running chat into a rolling memory so the conversation can continue in a fresh context window.
Return only the updated rolling memory in Markdown.
Preserve durable facts, user preferences, decisions, file names, code constraints, promises, unfinished work, and open questions.
Drop filler, duplicates, and wording that does not help future turns.
Use short sections named `Preferences`, `Facts`, `In Progress`, and `Open Loops`.
Stay concise but specific.
"""
    }

    private func preparedConversationContext(
        from history: [ChatMessage],
        conversation: Conversation
    ) -> PreparedConversationContext {
        let baseInstructions = settings.composedInstructions
        guard settings.usesConversationMemory else {
            return PreparedConversationContext(instructions: baseInstructions, messages: history)
        }

        let memoryDigest = effectiveMemoryDigest(for: conversation, historyCount: history.count)
        if let memoryDigest {
            let activeHistory = Array(history.dropFirst(memoryDigest.compactedMessageCount))
            return preparedConversationContext(
                fromActiveHistory: activeHistory,
                baseInstructions: baseInstructions,
                rollingMemory: memoryDigest.summary
            )
        }

        let recentCount = min(max(settings.recentContextMessageCount, 4), 20)
        let totalCharacterCount = history.reduce(0) { $0 + $1.approximateModelInputCharacterCount }

        guard history.count > recentCount + 4 || totalCharacterCount > 18_000 else {
            return PreparedConversationContext(instructions: baseInstructions, messages: history)
        }

        let anchorCount = min(2, max(history.count - recentCount, 1))
        let recentStartIndex = max(anchorCount, history.count - recentCount)
        guard recentStartIndex > anchorCount else {
            return PreparedConversationContext(instructions: baseInstructions, messages: history)
        }

        let anchorMessages = Array(history.prefix(anchorCount))
        let recentMessages = Array(history.suffix(from: recentStartIndex))
        let earlierMessages = Array(history[anchorCount..<recentStartIndex])

        guard let memoryBlock = compressedConversationMemory(from: earlierMessages) else {
            return PreparedConversationContext(instructions: baseInstructions, messages: history)
        }

        let instructions = [
            baseInstructions,
            """
Long-chat memory:
\(memoryBlock)

Treat the long-chat memory as compressed background context. Prefer the latest user turns whenever they conflict with older summarized context.
"""
        ].joined(separator: "\n\n")

        var packedMessages = anchorMessages
        packedMessages.append(contentsOf: recentMessages)

        return PreparedConversationContext(
            instructions: instructions,
            messages: deduplicatedMessages(packedMessages)
        )
    }

    private func preparedConversationContext(
        fromActiveHistory history: [ChatMessage],
        baseInstructions: String,
        rollingMemory: String
    ) -> PreparedConversationContext {
        let recentCount = min(max(settings.recentContextMessageCount, 4), 20)
        let totalCharacterCount = history.reduce(0) { $0 + $1.approximateModelInputCharacterCount }

        var instructionParts = [
            baseInstructions,
            """
Rolling conversation memory:
\(rollingMemory)

Treat the rolling conversation memory as authoritative background context for earlier turns. Prefer the latest verbatim turns whenever they conflict with older summarized context.
"""
        ]

        guard history.count > recentCount + 4 || totalCharacterCount > 18_000 else {
            return PreparedConversationContext(
                instructions: instructionParts.joined(separator: "\n\n"),
                messages: history
            )
        }

        let recentMessages = Array(history.suffix(recentCount))
        let earlierMessages = Array(history.dropLast(min(recentCount, history.count)))

        if let memoryBlock = compressedConversationMemory(from: earlierMessages) {
            instructionParts.append(
                """
Recent overflow memory:
\(memoryBlock)

Use this as supporting context for turns that happened after the rolling memory but before the recent verbatim transcript.
"""
            )
        }

        return PreparedConversationContext(
            instructions: instructionParts.joined(separator: "\n\n"),
            messages: deduplicatedMessages(recentMessages)
        )
    }

    private func effectiveMemoryDigest(
        for conversation: Conversation,
        historyCount: Int
    ) -> ConversationMemoryDigest? {
        guard var digest = conversation.memoryDigest else {
            return nil
        }

        digest.compactedMessageCount = min(max(digest.compactedMessageCount, 0), historyCount)
        guard !digest.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              digest.compactedMessageCount > 0 else {
            return nil
        }

        return digest
    }

    private func compressedConversationMemory(from messages: [ChatMessage]) -> String? {
        let maxMemoryCharacters = 12_000
        let perMessageLimit = 320
        var lines = ["Earlier conversation digest from older turns:"]
        var usedCharacters = lines[0].count
        var itemIndex = 1

        for message in messages {
            let excerpt = message.contextDigestExcerpt(limit: perMessageLimit)
            guard !excerpt.isEmpty else { continue }

            let roleTitle = message.role == .user ? "User" : "Assistant"
            let line = "\(itemIndex). \(roleTitle): \(excerpt)"
            let projectedLength = usedCharacters + line.count + 1

            guard projectedLength <= maxMemoryCharacters else {
                let overflowNotice = "... Older turns were compressed further to stay within budget."
                if usedCharacters + overflowNotice.count + 1 <= maxMemoryCharacters {
                    lines.append(overflowNotice)
                }
                break
            }

            lines.append(line)
            usedCharacters = projectedLength
            itemIndex += 1
        }

        return lines.count > 1 ? lines.joined(separator: "\n") : nil
    }

    private func assistantInstructions(baseInstructions: String, model: String) -> String {
        var sections: [String] = []

        if AppSettings.usesDirectOllamaAPI(model) {
            sections.append(AppSettings.sharedAssistantIdentityInstructions)
        }

        if AppSettings.usesResponsesServer(model) {
            sections.append(
                """
When the user asks about local weather, temperature, rain, snow, or forecasts for upcoming days, call the `\(WeatherService.forecastToolName)` tool instead of guessing.
Use the tool result's `fetched_at`, `age_minutes`, and `is_stale` fields to decide whether you should briefly mention that the weather snapshot is a bit outdated.
"""
            )
        } else if let fallbackForecastContext = weatherService.fallbackForecastContext() {
            sections.append(fallbackForecastContext)
        }

        sections.append(baseInstructions)

        return sections
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .joined(separator: "\n\n")
    }

    private func availableTools(for model: String) -> [ResponseFunctionToolDefinition] {
        guard AppSettings.usesResponsesServer(model) else {
            return []
        }

        return [weatherService.forecastTool]
    }

    private func toolOutputItems(for toolCalls: [ParsedResponseToolCall]) async -> [[String: Any]] {
        var items: [[String: Any]] = []

        for toolCall in toolCalls {
            let output: String
            switch toolCall.name {
            case WeatherService.forecastToolName:
                output = await weatherService.executeForecastTool(argumentsJSON: toolCall.argumentsJSON)
            default:
                output = #"{"status":"unavailable","reason":"That tool is not supported by the app."}"#
            }

            items.append([
                "type": "function_call_output",
                "call_id": toolCall.callID,
                "output": output
            ])
        }

        return items
    }

    private func resetAssistantStreamingMessage(in conversationID: UUID) {
        guard let conversationIndex = indexForConversation(conversationID),
              let messageIndex = conversations[conversationIndex].messages.lastIndex(where: { $0.role == .assistant && $0.state == .streaming }) else {
            return
        }

        conversations[conversationIndex].messages[messageIndex].content = ""
        conversations[conversationIndex].messages[messageIndex].thoughts = nil
        conversations[conversationIndex].messages[messageIndex].isThoughtsStreaming = true
        rawOutputBuffers[conversationID] = ""
        rawThoughtBuffers[conversationID] = ""
        touchConversation(at: conversationIndex)
    }

    private func deduplicatedMessages(_ messages: [ChatMessage]) -> [ChatMessage] {
        var seen = Set<UUID>()
        return messages.filter { seen.insert($0.id).inserted }
    }

    private func samplingProfile(for messages: [ChatMessage]) -> SamplingProfile {
        var temperature = settings.baseTemperature
        var topP = settings.topP

        switch settings.selectedReasoningEffort {
        case .low:
            break
        case .medium:
            temperature -= 0.03
            topP -= 0.01
        case .high:
            temperature -= 0.07
            topP -= 0.03
        }

        let totalCharacters = messages.reduce(0) { $0 + $1.approximateModelInputCharacterCount }
        let attachmentCount = messages.reduce(0) { $0 + $1.attachments.count }

        if messages.count >= 10 || totalCharacters >= 12_000 {
            temperature -= 0.04
            topP -= 0.02
        }

        if messages.count >= 18 || totalCharacters >= 22_000 {
            temperature -= 0.04
            topP -= 0.02
        }

        if attachmentCount > 0 {
            temperature -= 0.03
            topP -= 0.02
        }

        if settings.usesConversationMemory && messages.count >= settings.recentContextMessageCount {
            temperature -= 0.02
        }

        return SamplingProfile(
            temperature: min(max(temperature, 0.7), 1.1),
            topP: min(max(topP, 0.86), 0.98)
        )
    }

    private func modelWarmupRequest(model: String) -> ResponsesAPIRequest {
        let warmupMessage = ChatMessage(
            role: .user,
            content: "Reply with just the word ready."
        )
        return ResponsesAPIRequest(
            requestID: UUID().uuidString,
            baseURL: pinnedBaseURL,
            apiKey: settings.apiKey.nonEmpty,
            model: model,
            reasoningEffort: .low,
            temperature: 0.2,
            repeatPenalty: 0,
            topP: 0.9,
            // The gpt-oss responses server needs enough budget to finish a valid Harmony message.
            maxOutputTokens: 64,
            instructions: nil,
            messages: [warmupMessage]
        )
    }

    private func prewarmLaunchModels(_ models: [String]) async throws {
        let pendingModels = models.filter { !warmedLaunchModels.contains($0) }
        guard !pendingModels.isEmpty else { return }

        for model in pendingModels {
            try Task.checkCancellation()

            let request = modelWarmupRequest(model: model)
            let stream = client.streamResponse(for: request)
            for try await _ in stream {
                try Task.checkCancellation()
            }

            warmedLaunchModels.insert(model)
        }
    }
}

private struct PreparedConversationContext {
    let instructions: String
    let messages: [ChatMessage]
}

private struct AssistantReplyPlan {
    let preparedContext: PreparedConversationContext
    let request: ResponsesAPIRequest
}

private struct ConversationCompactionPlan {
    let request: ResponsesAPIRequest
    let compactedMessageCount: Int
}

private struct SamplingProfile {
    let temperature: Double
    let topP: Double
}

private enum ReviewedStreamStage {
    case primary
    case reviewer
}

private struct ReviewedStageResult {
    let transcript: ReviewedThoughtTranscript
    let payload: ParsedResponsePayload
}

private struct ReviewedThoughtTranscript {
    let primaryModelDisplayName: String
    let reviewerModelDisplayName: String

    private var primaryThoughts = ""
    private var primaryResult = ""
    private var reviewerThoughts = ""
    private var reviewerResult = ""

    init(primaryModelDisplayName: String, reviewerModelDisplayName: String) {
        self.primaryModelDisplayName = primaryModelDisplayName
        self.reviewerModelDisplayName = reviewerModelDisplayName
    }

    mutating func apply(_ event: ResponsesAPIStreamEvent, to stage: ReviewedStreamStage) {
        switch event {
        case .thoughtsDelta(let delta):
            append(delta, to: stage, kind: .thoughts)
        case .outputDelta(let delta):
            append(delta, to: stage, kind: .result)
        case .completed(let payload):
            if let thoughts = payload.thoughts {
                replace(thoughts, on: stage, kind: .thoughts)
            }
            if let finalText = payload.outputText.nonEmpty {
                replace(finalText, on: stage, kind: .result)
            }
        }
    }

    mutating func reset(stage: ReviewedStreamStage) {
        switch stage {
        case .primary:
            primaryThoughts = ""
            primaryResult = ""
        case .reviewer:
            reviewerThoughts = ""
            reviewerResult = ""
        }
    }

    func payload(for stage: ReviewedStreamStage) -> ParsedResponsePayload {
        switch stage {
        case .primary:
            return ParsedResponsePayload(
                outputText: normalized(primaryResult) ?? "",
                thoughts: normalized(primaryThoughts)
            )
        case .reviewer:
            return ParsedResponsePayload(
                outputText: normalized(reviewerResult) ?? "",
                thoughts: normalized(reviewerThoughts)
            )
        }
    }

    var markdown: String? {
        let sections = [
            section(
                title: "OSS Thoughts (\(primaryModelDisplayName))",
                content: normalized(primaryThoughts)
            ),
            section(
                title: "OSS Result (\(primaryModelDisplayName))",
                content: normalized(primaryResult)
            ),
            section(
                title: "Qwen Thoughts (\(reviewerModelDisplayName))",
                content: normalized(reviewerThoughts)
            ),
            section(
                title: "Qwen Result (\(reviewerModelDisplayName))",
                content: normalized(reviewerResult)
            )
        ]
        .compactMap { $0 }

        guard !sections.isEmpty else {
            return nil
        }

        return sections.joined(separator: "\n\n")
    }

    private enum SectionKind {
        case thoughts
        case result
    }

    private mutating func append(_ text: String, to stage: ReviewedStreamStage, kind: SectionKind) {
        guard !text.isEmpty else { return }

        switch (stage, kind) {
        case (.primary, .thoughts):
            primaryThoughts += text
        case (.primary, .result):
            primaryResult += text
        case (.reviewer, .thoughts):
            reviewerThoughts += text
        case (.reviewer, .result):
            reviewerResult += text
        }
    }

    private mutating func replace(_ text: String, on stage: ReviewedStreamStage, kind: SectionKind) {
        switch (stage, kind) {
        case (.primary, .thoughts):
            primaryThoughts = text
        case (.primary, .result):
            primaryResult = text
        case (.reviewer, .thoughts):
            reviewerThoughts = text
        case (.reviewer, .result):
            reviewerResult = text
        }
    }

    private func section(title: String, content: String?) -> String? {
        guard let content else { return nil }
        return "### \(title)\n\n\(content)"
    }

    private func normalized(_ text: String) -> String? {
        let sanitized = ModelOutputSanitizer.sanitize(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? nil : sanitized
    }
}

private extension ChatMessage {
    var approximateModelInputCharacterCount: Int {
        content.count + attachments.reduce(0) { $0 + $1.modelInputText.count }
    }

    func contextDigestExcerpt(limit: Int) -> String {
        var parts: [String] = []
        let text = trimmedContent.compactingWhitespace()

        if !text.isEmpty {
            parts.append(text)
        }

        let attachmentSummaries = attachments.prefix(2).map { $0.contextDigestExcerpt(limit: 180) }
        parts.append(contentsOf: attachmentSummaries.filter { !$0.isEmpty })

        if attachments.count > 2 {
            parts.append("+\(attachments.count - 2) more attachments")
        }

        let combined = parts
            .joined(separator: " | ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return combined.truncated(to: limit)
    }
}

private extension ChatAttachment {
    func contextDigestExcerpt(limit: Int) -> String {
        var summary = "Attachment \(fileName)"
        let snippet = extractedText.compactingWhitespace().truncated(to: 160)

        if !snippet.isEmpty {
            summary += ": \(snippet)"
        }

        if wasTruncated {
            summary += " [truncated]"
        }

        return summary.truncated(to: limit)
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : self
    }

    func compactingWhitespace() -> String {
        split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    func truncated(to limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard count > limit else { return self }

        let cutoff = index(startIndex, offsetBy: max(limit - 1, 0))
        return String(self[..<cutoff]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

private extension ResponsesAPIRequest {
    func replacing(
        requestID: String,
        inputItems: [[String: Any]]
    ) -> ResponsesAPIRequest {
        ResponsesAPIRequest(
            requestID: requestID,
            baseURL: baseURL,
            apiKey: apiKey,
            model: model,
            reasoningEffort: reasoningEffort,
            temperature: temperature,
            repeatPenalty: repeatPenalty,
            topP: topP,
            maxOutputTokens: maxOutputTokens,
            instructions: instructions,
            messages: messages,
            inputItems: inputItems,
            tools: tools
        )
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
    private static let inferenceBackend = "ollama"
    private static let ollamaWarmupTimeout: TimeInterval = 20
    private static let ollamaLaunchTimeoutNanoseconds: UInt64 = 10_000_000_000

    private let session: URLSession
    private let fileManager = FileManager.default
    private let baseURL = URL(string: AppSettings.defaultBaseURL)!
    private let serverURL: URL
    private let ollamaURL = URL(string: "http://127.0.0.1:11434/api/tags")!
    private let runtimeRootURL: URL
    private let workingDirectoryURL: URL
    private let pythonURL: URL

    private var process: Process?
    private var outputPipe: Pipe?
    private var ownsProcess = false
    private var recentLogs = ""
    private var currentModelReference = AppSettings.defaultModelIdentifier

    init(
        session: URLSession = .shared,
        sourceFilePath: String = #filePath
    ) {
        let localFileManager = FileManager.default

        self.session = session
        self.serverURL = baseURL.appending(path: "responses")

        let appSupportURL = localFileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support", directoryHint: .isDirectory)
        self.runtimeRootURL = appSupportURL
            .appending(path: "llocust", directoryHint: .isDirectory)
            .appending(path: "runtime", directoryHint: .isDirectory)

        let sourceURL = URL(fileURLWithPath: sourceFilePath)
        let repositoryRoot = sourceURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let defaultWorkingDirectoryURL = repositoryRoot.appending(path: "gpt-oss", directoryHint: .isDirectory)

        let bundledRuntimeURL = runtimeRootURL.appending(path: "gpt-oss", directoryHint: .isDirectory)
        let configuredRuntimeURL: URL
        if let overridePath = ProcessInfo.processInfo.environment["LLOCUST_RUNTIME_ROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !overridePath.isEmpty {
            configuredRuntimeURL = URL(fileURLWithPath: overridePath, isDirectory: true)
        } else {
            let runtimeCandidates = [defaultWorkingDirectoryURL, bundledRuntimeURL]
            if let detectedRuntimeURL = runtimeCandidates.first(where: { Self.isUsableRuntime(at: $0, fileManager: localFileManager) }) {
                configuredRuntimeURL = detectedRuntimeURL
            } else if localFileManager.isExecutableFile(atPath: defaultWorkingDirectoryURL.appending(path: ".venv/bin/python").path) {
                configuredRuntimeURL = defaultWorkingDirectoryURL
            } else {
                configuredRuntimeURL = bundledRuntimeURL
            }
        }

        self.workingDirectoryURL = configuredRuntimeURL
        self.pythonURL = workingDirectoryURL.appending(path: ".venv/bin/python")

        if !localFileManager.fileExists(atPath: workingDirectoryURL.path),
           !configuredRuntimeURL.standardizedFileURL.path.hasPrefix(defaultWorkingDirectoryURL.standardizedFileURL.path) {
            NSLog("llocust runtime missing at %@", workingDirectoryURL.path)
        }
    }

    private static func isUsableRuntime(at runtimeURL: URL, fileManager: FileManager) -> Bool {
        let pythonURL = runtimeURL.appending(path: ".venv/bin/python")
        let packageInitURL = runtimeURL.appending(path: "gpt_oss/__init__.py")
        let serverModuleURL = runtimeURL.appending(path: "gpt_oss/responses_api/serve.py")

        return fileManager.isExecutableFile(atPath: pythonURL.path)
            && fileManager.fileExists(atPath: packageInitURL.path)
            && fileManager.fileExists(atPath: serverModuleURL.path)
    }

    func ensureRunning(modelReference: String) async throws {
        let normalizedModelReference = AppSettings.canonicalModelIdentifier(modelReference)
        try await ensureOllamaServiceReady()

        if await isReachable() {
            if !ownsProcess {
                currentModelReference = normalizedModelReference
                return
            }

            if currentModelReference == normalizedModelReference {
                return
            }
        }

        if let process, process.isRunning, currentModelReference == normalizedModelReference {
            try await waitUntilReachableOrExit(process)
            return
        }

        try await forceRestart(modelReference: normalizedModelReference)
    }

    func stopIfNeeded() async {
        guard ownsProcess, let process, process.isRunning else { return }
        process.terminate()
    }

    func forceRestart(modelReference: String) async throws {
        let normalizedModelReference = AppSettings.canonicalModelIdentifier(modelReference)
        try await ensureOllamaServiceReady()

        if ownsProcess, let process, process.isRunning {
            process.terminate()
        }

        handleProcessTermination()
        try terminateAnyServerListeningOnPort()
        try validateRuntime(modelReference: normalizedModelReference)
        try startProcess(modelReference: normalizedModelReference)

        guard let process else {
            throw LocalModelServerError.startupFailed("The local server could not be relaunched.")
        }

        try await waitUntilReachableOrExit(process)
    }

    private func validateRuntime(modelReference: String) throws {
        guard fileManager.fileExists(atPath: workingDirectoryURL.path) else {
            throw LocalModelServerError.missingRuntime(workingDirectoryURL.path)
        }

        guard fileManager.isExecutableFile(atPath: pythonURL.path) else {
            throw LocalModelServerError.missingPython(pythonURL.path)
        }

        if Self.inferenceBackend != "ollama" {
            throw LocalModelServerError.missingCheckpoint(modelReference)
        }
    }

    private func startProcess(modelReference: String) throws {
        let process = Process()
        let pipe = Pipe()

        recentLogs = ""
        ownsProcess = true
        currentModelReference = modelReference

        process.executableURL = pythonURL
        process.currentDirectoryURL = workingDirectoryURL
        process.arguments = [
            "-m",
            "gpt_oss.responses_api.serve",
            "--checkpoint",
            modelReference,
            "--port",
            "\(baseURL.port ?? 8412)",
            "--inference-backend",
            Self.inferenceBackend
        ]

        var environment = ProcessInfo.processInfo.environment
        let strippedEnvironmentKeys = [
            "DYLD_INSERT_LIBRARIES",
            "__XPC_DYLD_INSERT_LIBRARIES",
            "__XCODE_BUILT_PRODUCTS_DIR_PATHS",
            "OS_ACTIVITY_DT_MODE"
        ]
        strippedEnvironmentKeys.forEach { environment.removeValue(forKey: $0) }
        environment["PYTHONUNBUFFERED"] = "1"
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
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }
            return isReachableResponsesStatus(httpResponse.statusCode)
        } catch {
            return false
        }
    }

    private func isReachableResponsesStatus(_ statusCode: Int) -> Bool {
        (200...299).contains(statusCode) || statusCode == 401 || statusCode == 403 || statusCode == 405
    }

    private func ensureOllamaServiceReady() async throws {
        guard Self.inferenceBackend == "ollama" else { return }

        if await isOllamaReachable() {
            return
        }

        try warmOllamaService()

        let pollIntervalNanoseconds: UInt64 = 500_000_000
        var waitedNanoseconds: UInt64 = 0

        while waitedNanoseconds < Self.ollamaLaunchTimeoutNanoseconds {
            if await isOllamaReachable() {
                return
            }

            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            waitedNanoseconds += pollIntervalNanoseconds
        }

        throw LocalModelServerError.ollamaUnavailable(
            "Start the Ollama app or run `ollama serve`, then try sending the message again."
        )
    }

    private func isOllamaReachable() async -> Bool {
        var request = URLRequest(url: ollamaURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 2

        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }
            return (200...299).contains(httpResponse.statusCode)
        } catch {
            return false
        }
    }

    private func warmOllamaService() throws {
        let process = Process()
        let outputPipe = Pipe()
        let semaphore = DispatchSemaphore(value: 0)

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ollama", "list"]
        process.currentDirectoryURL = workingDirectoryURL
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.terminationHandler = { _ in
            semaphore.signal()
        }

        do {
            try process.run()
        } catch {
            throw LocalModelServerError.ollamaUnavailable(
                "The `ollama` command could not be launched automatically. Start the Ollama app or run `ollama serve`, then try again."
            )
        }

        let timedOut = semaphore.wait(timeout: .now() + Self.ollamaWarmupTimeout) == .timedOut
        if timedOut {
            process.terminate()
            _ = semaphore.wait(timeout: .now() + 2)
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: outputData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !output.isEmpty {
            recentLogs += "\n[ollama]\n" + output
            let maxCharacters = 8_000
            if recentLogs.count > maxCharacters {
                recentLogs = String(recentLogs.suffix(maxCharacters))
            }
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
        ownsProcess = false
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
    case missingRuntime(String)
    case missingPython(String)
    case missingCheckpoint(String)
    case ollamaUnavailable(String?)
    case startupFailed(String?)
    case startupTimedOut(String?)

    var errorDescription: String? {
        switch self {
        case .missingRuntime(let path):
            return "The local model runtime is not installed at \(path)."
        case .missingPython(let path):
            return "The local model runtime is missing its Python executable at \(path)."
        case .missingCheckpoint(let path):
            return "The selected Ollama model is unavailable: \(path)."
        case .ollamaUnavailable(let details):
            if let details, !details.isEmpty {
                return "Ollama isn’t reachable on 127.0.0.1:11434.\n\n\(details)"
            }
            return "Ollama isn’t reachable on 127.0.0.1:11434. Start the Ollama app or run `ollama serve`, then try again."
        case .startupFailed(let logs):
            if let logs, !logs.isEmpty {
                return "The local model server exited while starting.\n\n\(logs)"
            }
            return "The local model server exited while starting."
        case .startupTimedOut(let logs):
            if let logs, !logs.isEmpty {
                return "The local model server took too long to start.\n\n\(logs)"
            }
            return "The local model server took too long to start."
        }
    }
}
