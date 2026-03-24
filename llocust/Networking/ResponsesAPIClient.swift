import Foundation

enum ResponsesAPIError: LocalizedError {
    case invalidBaseURL(String)
    case serverUnavailable(String)
    case server(status: Int, message: String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let value):
            return "The server URL is invalid: \(value)"
        case .serverUnavailable(let message):
            return message
        case .server(let status, let message):
            return "The local server returned \(status): \(message)"
        case .malformedResponse:
            return "The local server returned a response llocust could not parse."
        }
    }
}

struct ResponsesAPIRequest {
    let requestID: String
    let baseURL: URL
    let apiKey: String?
    let model: String
    let reasoningEffort: ReasoningEffort
    let temperature: Double
    let repeatPenalty: Double
    let topP: Double
    let maxOutputTokens: Int?
    let instructions: String?
    let messages: [ChatMessage]
    let inputItems: [[String: Any]]
    let tools: [ResponseFunctionToolDefinition]

    init(
        requestID: String,
        baseURL: URL,
        apiKey: String?,
        model: String,
        reasoningEffort: ReasoningEffort,
        temperature: Double,
        repeatPenalty: Double,
        topP: Double,
        maxOutputTokens: Int?,
        instructions: String?,
        messages: [ChatMessage],
        inputItems: [[String: Any]] = [],
        tools: [ResponseFunctionToolDefinition] = []
    ) {
        self.requestID = requestID
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.temperature = temperature
        self.repeatPenalty = repeatPenalty
        self.topP = topP
        self.maxOutputTokens = maxOutputTokens
        self.instructions = instructions
        self.messages = messages
        self.inputItems = inputItems
        self.tools = tools
    }
}

struct ResponsesServerMetadata {
    let baseURL: URL
    let models: [String]
}

enum ResponsesAPIStreamEvent {
    case thoughtsDelta(String)
    case outputDelta(String)
    case completed(ParsedResponsePayload)
}

final class ResponsesAPIClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func completeResponse(for request: ResponsesAPIRequest) async throws -> ParsedResponsePayload {
        if AppSettings.usesDirectOllamaAPI(request.model) {
            return try await completeOllamaChatResponse(for: request)
        }

        let urlRequest = try makeURLRequest(for: request, streaming: false)
        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError {
            throw translated(urlError: error)
        }

        try validate(response: response, data: data)
        return try ResponsesPayloadParser.parseResponse(data: data)
    }

    func streamResponse(for request: ResponsesAPIRequest) -> AsyncThrowingStream<ResponsesAPIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if AppSettings.usesDirectOllamaAPI(request.model) {
                        try await self.executeOllamaStreamingRequest(request, continuation: continuation)
                    } else {
                        try await self.executeStreamingRequest(request, continuation: continuation)
                    }
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func cancelResponses(baseURL: URL, apiKey: String?, requestIDs: [String]) async throws {
        let normalizedRequestIDs = Array(Set(requestIDs.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }))
        guard !normalizedRequestIDs.isEmpty else { return }

        let endpoint = baseURL.appending(path: "responses/cancel")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["request_ids": normalizedRequestIDs],
            options: []
        )

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
    }

    func resolveServerMetadata(
        preferredBaseURL: URL,
        apiKey: String?
    ) async throws -> ResponsesServerMetadata {
        let candidates = candidateBaseURLs(from: preferredBaseURL)
        var lastError: Error?

        for candidate in candidates {
            do {
                let models = try await fetchModels(baseURL: candidate, apiKey: apiKey)
                return ResponsesServerMetadata(baseURL: candidate, models: models)
            } catch {
                lastError = error
            }
        }

        if let reachableBaseURL = try await probeResponsesEndpoint(baseURLs: candidates, apiKey: apiKey) {
            return ResponsesServerMetadata(baseURL: reachableBaseURL, models: [])
        }

        throw lastError ?? ResponsesAPIError.serverUnavailable("Couldn’t connect to the local server.")
    }

    func fetchModels(baseURL: URL, apiKey: String?) async throws -> [String] {
        do {
            let request = try makeModelsRequest(baseURL: baseURL, apiKey: apiKey, path: "models")
            let (data, response) = try await session.data(for: request)
            try validate(response: response, data: data)

            if
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let dataItems = object["data"] as? [[String: Any]]
            {
                let models = dataItems.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
                if !models.isEmpty {
                    return models
                }
            }
        } catch {
            if case ResponsesAPIError.serverUnavailable = error {
                throw error
            }
        }

        for ollamaBaseURL in ollamaBaseURLs(from: baseURL) {
            do {
                let ollamaRequest = try makeModelsRequest(baseURL: ollamaBaseURL, apiKey: apiKey, path: "api/tags")
                let (data, response) = try await session.data(for: ollamaRequest)
                try validate(response: response, data: data)

                if
                    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let models = object["models"] as? [[String: Any]]
                {
                    let discoveredModels = models.compactMap { ($0["name"] as? String) ?? ($0["model"] as? String) }
                    if !discoveredModels.isEmpty {
                        return discoveredModels
                    }
                }
            } catch {
                continue
            }
        }

        return []
    }

    private func completeOllamaChatResponse(for request: ResponsesAPIRequest) async throws -> ParsedResponsePayload {
        let urlRequest = try makeOllamaChatRequest(for: request, streaming: false)
        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError {
            throw translated(urlError: error)
        }

        try validate(response: response, data: data)

        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = object["message"] as? [String: Any]
        else {
            throw ResponsesAPIError.malformedResponse
        }

        let outputText = (message["content"] as? String) ?? ""
        let thoughts = (message["thinking"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedResponsePayload(
            outputText: ModelOutputSanitizer.sanitize(outputText),
            thoughts: thoughts?.isEmpty == true ? nil : ModelOutputSanitizer.sanitize(thoughts ?? "")
        )
    }

    private func executeStreamingRequest(
        _ request: ResponsesAPIRequest,
        continuation: AsyncThrowingStream<ResponsesAPIStreamEvent, Error>.Continuation
    ) async throws {
        let urlRequest = try makeURLRequest(for: request, streaming: true)
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)

        do {
            (bytes, response) = try await session.bytes(for: urlRequest)
        } catch let error as URLError {
            throw translated(urlError: error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ResponsesAPIError.malformedResponse
        }

        if !(200...299).contains(httpResponse.statusCode) {
            let data = try await collectData(from: bytes)
            let message = errorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw ResponsesAPIError.server(status: httpResponse.statusCode, message: message)
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if contentType.contains("text/event-stream") {
            try await consumeEventStream(bytes: bytes, continuation: continuation)
        } else {
            let data = try await collectData(from: bytes)
            let parsed = try ResponsesPayloadParser.parseResponse(data: data)
            continuation.yield(.completed(parsed))
            continuation.finish()
        }
    }

    private func executeOllamaStreamingRequest(
        _ request: ResponsesAPIRequest,
        continuation: AsyncThrowingStream<ResponsesAPIStreamEvent, Error>.Continuation
    ) async throws {
        let urlRequest = try makeOllamaChatRequest(for: request, streaming: true)
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)

        do {
            (bytes, response) = try await session.bytes(for: urlRequest)
        } catch let error as URLError {
            throw translated(urlError: error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ResponsesAPIError.malformedResponse
        }

        if !(200...299).contains(httpResponse.statusCode) {
            let data = try await collectData(from: bytes)
            let message = errorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw ResponsesAPIError.server(status: httpResponse.statusCode, message: message)
        }

        var finalText = ""
        var finalThoughts = ""
        var sawCompletionMarker = false

        do {
            for try await line in bytes.lines {
                if Task.isCancelled {
                    throw CancellationError()
                }

                let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedLine.isEmpty,
                      let data = trimmedLine.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    continue
                }

                if
                    let message = object["message"] as? [String: Any],
                    let thinking = (message["thinking"] as? String)?.trimmingCharacters(in: .newlines),
                    !thinking.isEmpty
                {
                    finalThoughts += thinking
                    continuation.yield(.thoughtsDelta(thinking))
                }

                if
                    let message = object["message"] as? [String: Any],
                    let delta = (message["content"] as? String)?.trimmingCharacters(in: .newlines),
                    !delta.isEmpty
                {
                    finalText += delta
                    continuation.yield(.outputDelta(delta))
                }

                if (object["done"] as? Bool) == true {
                    sawCompletionMarker = true
                    continuation.yield(
                        .completed(
                            ParsedResponsePayload(
                                outputText: finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : ModelOutputSanitizer.sanitize(finalText),
                                thoughts: finalThoughts.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : ModelOutputSanitizer.sanitize(finalThoughts)
                            )
                        )
                    )
                    continuation.finish()
                    return
                }
            }
        } catch let error as URLError {
            throw translated(urlError: error)
        } catch {
            throw error
        }

        if !sawCompletionMarker,
           finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           finalThoughts.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ResponsesAPIError.serverUnavailable(
                "Ollama ended the streamed reply before returning any assistant text. Make sure Ollama is running and try again."
            )
        }

        continuation.yield(
            .completed(
                ParsedResponsePayload(
                    outputText: finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : ModelOutputSanitizer.sanitize(finalText),
                    thoughts: finalThoughts.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : ModelOutputSanitizer.sanitize(finalThoughts)
                )
            )
        )
        continuation.finish()
    }

    private func makeURLRequest(for request: ResponsesAPIRequest, streaming: Bool) throws -> URLRequest {
        let endpoint = request.baseURL.appending(path: "responses")
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 180
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(request.requestID, forHTTPHeaderField: "X-OssChat-Request-ID")
        urlRequest.setValue(request.requestID, forHTTPHeaderField: "X-llocust-Request-ID")

        if let apiKey = request.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        var input = request.messages.compactMap { message -> [String: Any]? in
            var contentItems: [[String: Any]] = []
            let contentType = message.role == .user ? "input_text" : "output_text"

            if !message.trimmedContent.isEmpty {
                contentItems.append([
                    "type": contentType,
                    "text": message.content
                ])
            }

            for attachment in message.attachments {
                contentItems.append([
                    "type": contentType,
                    "text": attachment.modelInputText
                ])
            }

            guard !contentItems.isEmpty else { return nil }

            return [
                "role": message.role.rawValue,
                "content": contentItems
            ]
        }
        input.append(contentsOf: request.inputItems)

        let payload: [String: Any] = [
            "model": request.model,
            "input": input,
            "stream": streaming,
            "temperature": request.temperature,
            "frequency_penalty": request.repeatPenalty,
            "top_p": request.topP,
            "reasoning": [
                "effort": request.reasoningEffort.rawValue
            ]
        ]

        var finalizedPayload = payload
        if let instructions = request.instructions?.trimmingCharacters(in: .whitespacesAndNewlines), !instructions.isEmpty {
            finalizedPayload["instructions"] = instructions
        }
        if let maxOutputTokens = request.maxOutputTokens {
            finalizedPayload["max_output_tokens"] = maxOutputTokens
        }
        if !request.tools.isEmpty {
            finalizedPayload["tools"] = request.tools.map(\.payload)
        }

        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: finalizedPayload, options: [])
        return urlRequest
    }

    private func makeOllamaChatRequest(for request: ResponsesAPIRequest, streaming: Bool) throws -> URLRequest {
        let endpoint = preferredOllamaBaseURL(from: request.baseURL).appending(path: "api/chat")
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 180
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")

        let messages = ollamaMessages(for: request)
        let payload: [String: Any] = [
            "model": request.model,
            "messages": messages,
            "stream": streaming,
            "think": ollamaThinkingValue(for: request),
            "options": [
                "temperature": request.temperature,
                "top_p": request.topP,
                "repeat_penalty": 1.0 + max(0.0, request.repeatPenalty)
            ]
        ]

        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        return urlRequest
    }

    private func makeModelsRequest(baseURL: URL, apiKey: String?, path: String) throws -> URLRequest {
        let endpoint = baseURL.appending(path: path)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        return request
    }

    private func consumeEventStream(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<ResponsesAPIStreamEvent, Error>.Continuation
    ) async throws {
        var currentEventName: String?
        var currentDataLines: [String] = []
        var sawAnyPayload = false
        var sawAssistantContent = false
        var sawCompletedEvent = false

        func flushEvent() {
            defer {
                currentEventName = nil
                currentDataLines.removeAll(keepingCapacity: true)
            }

            guard !currentDataLines.isEmpty else { return }
            let payload = currentDataLines.joined(separator: "\n")
            guard payload != "[DONE]" else {
                return
            }
            guard let data = payload.data(using: .utf8) else { return }
            sawAnyPayload = true

            let loweredEventName = (currentEventName ?? "").lowercased()
            if loweredEventName == "response.completed" {
                sawCompletedEvent = true
            }

            for item in ResponsesPayloadParser.parseStreamingEvent(data: data, eventName: currentEventName) {
                switch item {
                case .thoughtsDelta(let delta):
                    sawAssistantContent = true
                    continuation.yield(.thoughtsDelta(delta))
                case .outputDelta(let delta):
                    sawAssistantContent = true
                    continuation.yield(.outputDelta(delta))
                case .completed(let payload):
                    sawCompletedEvent = true
                    if payload.outputText.nonEmpty != nil || payload.thoughts != nil || !payload.toolCalls.isEmpty {
                        sawAssistantContent = true
                    }
                    continuation.yield(.completed(payload))
                }
            }
        }

        do {
            for try await line in bytes.lines {
                if Task.isCancelled {
                    throw CancellationError()
                }

                // URLSession.AsyncBytes.lines may omit SSE blank separator lines on macOS,
                // so flush the previous event when the next event header starts.
                if line.hasPrefix("event:"), !currentDataLines.isEmpty {
                    flushEvent()
                }

                if line.isEmpty {
                    flushEvent()
                    continue
                }

                if line.hasPrefix("event:") {
                    currentEventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("data:") {
                    let dataLine = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    currentDataLines.append(dataLine)
                }
            }
            flushEvent()
        } catch let error as URLError {
            throw translated(urlError: error)
        } catch {
            throw error
        }

        if sawCompletedEvent || sawAssistantContent {
            continuation.finish()
            return
        }

        if sawAnyPayload {
            throw ResponsesAPIError.serverUnavailable(
                "The local model backend stopped the reply stream before returning any assistant text. Make sure Ollama is running and try again."
            )
        }

        throw ResponsesAPIError.serverUnavailable(
            "The local server closed the reply stream without returning any events."
        )
    }

    private func collectData(from bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
            }
            return data
        } catch let error as URLError {
            throw translated(urlError: error)
        } catch {
            throw error
        }
    }

    private func errorMessage(from data: Data) -> String? {
        if
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = object["error"] as? [String: Any],
            let message = error["message"] as? String
        {
            return message
        }

        if
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let detail = object["detail"] as? String,
            !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return detail
        }

        if
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = object["message"] as? String,
            !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return message
        }

        if let string = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty {
            return string
        }
        return nil
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ResponsesAPIError.malformedResponse
        }

        if !(200...299).contains(httpResponse.statusCode) {
            let message = errorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw ResponsesAPIError.server(status: httpResponse.statusCode, message: message)
        }
    }

    private func probeResponsesEndpoint(baseURLs: [URL], apiKey: String?) async throws -> URL? {
        var lastError: Error?

        for baseURL in baseURLs {
            let endpoint = baseURL.appending(path: "responses")
            var request = URLRequest(url: endpoint)
            request.httpMethod = "GET"
            request.timeoutInterval = 10
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            if let apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }

            do {
                let (_, response) = try await session.data(for: request)
                if let httpResponse = response as? HTTPURLResponse,
                   isReachableResponsesStatus(httpResponse.statusCode) {
                    return baseURL
                }
            } catch {
                lastError = error
            }
        }

        if let lastError {
            throw lastError
        }

        return nil
    }

    private func isReachableResponsesStatus(_ statusCode: Int) -> Bool {
        (200...299).contains(statusCode) || statusCode == 401 || statusCode == 403 || statusCode == 405
    }

    private func candidateBaseURLs(from preferredBaseURL: URL) -> [URL] {
        let normalized = normalizedBaseURL(preferredBaseURL)
        return [normalized]
    }

    private func normalizedBaseURL(_ baseURL: URL) -> URL {
        let trimmed = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: trimmed) ?? baseURL
    }

    private func strippedBaseURL(_ baseURL: URL) -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return baseURL
        }
        if components.path.hasSuffix("/v1") {
            components.path = String(components.path.dropLast(3))
        }
        return components.url ?? baseURL
    }

    private func ollamaBaseURLs(from baseURL: URL) -> [URL] {
        let fallbacks = [
            URL(string: "http://127.0.0.1:11434"),
            URL(string: "http://localhost:11434"),
            strippedBaseURL(baseURL)
        ]

        var seen = Set<String>()
        return fallbacks.compactMap { candidate in
            guard let candidate else { return nil }
            let normalized = candidate.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard seen.insert(normalized).inserted else { return nil }
            return URL(string: normalized) ?? candidate
        }
    }

    private func preferredOllamaBaseURL(from baseURL: URL) -> URL {
        ollamaBaseURLs(from: baseURL).first ?? baseURL
    }

    private func ollamaMessages(for request: ResponsesAPIRequest) -> [[String: String]] {
        var messages: [[String: String]] = []

        if let instructions = request.instructions?.trimmingCharacters(in: .whitespacesAndNewlines), !instructions.isEmpty {
            messages.append([
                "role": "system",
                "content": instructions
            ])
        }

        for message in request.messages {
            let parts = ([message.trimmedContent] + message.attachments.map(\.modelInputText))
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !parts.isEmpty else { continue }

            messages.append([
                "role": message.role.rawValue,
                "content": parts.joined(separator: "\n\n")
            ])
        }

        return messages
    }

    private func ollamaThinkingValue(for request: ResponsesAPIRequest) -> Bool {
        switch request.reasoningEffort {
        case .low:
            return false
        case .medium, .high:
            return true
        }
    }

    private func translated(urlError: URLError) -> ResponsesAPIError {
        switch urlError.code {
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet, .timedOut:
            return .serverUnavailable("Couldn’t connect to the local server. Make sure your local model server is running and reachable.")
        default:
            return .serverUnavailable(urlError.localizedDescription)
        }
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : self
    }
}
