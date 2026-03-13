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
    let instructions: String?
    let messages: [ChatMessage]
}

struct ResponsesServerMetadata {
    let baseURL: URL
    let models: [String]
}

enum ResponsesAPIStreamEvent {
    case thoughtsDelta(String)
    case outputDelta(String)
    case completed(finalText: String?, thoughts: String?)
}

final class ResponsesAPIClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func streamResponse(for request: ResponsesAPIRequest) -> AsyncThrowingStream<ResponsesAPIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.executeStreamingRequest(request, continuation: continuation)
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
            if let translated = error as? ResponsesAPIError {
                throw translated
            }
        }

        let ollamaRequest = try makeModelsRequest(baseURL: strippedBaseURL(baseURL), apiKey: apiKey, path: "api/tags")
        let (data, response) = try await session.data(for: ollamaRequest)
        try validate(response: response, data: data)

        if
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let models = object["models"] as? [[String: Any]]
        {
            return models.compactMap { ($0["name"] as? String) ?? ($0["model"] as? String) }
        }

        return []
    }

    private func executeStreamingRequest(
        _ request: ResponsesAPIRequest,
        continuation: AsyncThrowingStream<ResponsesAPIStreamEvent, Error>.Continuation
    ) async throws {
        let urlRequest = try makeURLRequest(for: request, streaming: true)
        let (bytes, response) = try await session.bytes(for: urlRequest)

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
            continuation.yield(.completed(finalText: parsed.outputText.nonEmpty, thoughts: parsed.thoughts))
            continuation.finish()
        }
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

        let input = request.messages.compactMap { message -> [String: Any]? in
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

        let payload: [String: Any] = [
            "model": request.model,
            "input": input,
            "stream": streaming,
            "reasoning": [
                "effort": request.reasoningEffort.rawValue
            ]
        ]

        var finalizedPayload = payload
        if let instructions = request.instructions?.trimmingCharacters(in: .whitespacesAndNewlines), !instructions.isEmpty {
            finalizedPayload["instructions"] = instructions
        }

        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: finalizedPayload, options: [])
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

        func flushEvent() {
            defer {
                currentEventName = nil
                currentDataLines.removeAll(keepingCapacity: true)
            }

            guard !currentDataLines.isEmpty else { return }
            let payload = currentDataLines.joined(separator: "\n")
            guard payload != "[DONE]" else {
                continuation.finish()
                return
            }
            guard let data = payload.data(using: .utf8) else { return }

            for item in ResponsesPayloadParser.parseStreamingEvent(data: data, eventName: currentEventName) {
                switch item {
                case .thoughtsDelta(let delta):
                    continuation.yield(.thoughtsDelta(delta))
                case .outputDelta(let delta):
                    continuation.yield(.outputDelta(delta))
                case .completed(let finalText, let thoughts):
                    continuation.yield(.completed(finalText: finalText, thoughts: thoughts))
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
            continuation.finish()
        } catch let error as URLError {
            throw translated(urlError: error)
        } catch {
            throw error
        }
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
                if response is HTTPURLResponse {
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
