import Foundation

struct ParsedResponsePayload {
    var outputText: String
    var thoughts: String?
}

enum ParsedStreamingPayload {
    case thoughtsDelta(String)
    case outputDelta(String)
    case completed(finalText: String?, thoughts: String?)
}

enum ResponsesPayloadParser {
    static func parseResponse(data: Data) throws -> ParsedResponsePayload {
        let json = try JSONSerialization.jsonObject(with: data)
        return parseResponse(jsonObject: json)
    }

    static func parseResponse(jsonObject: Any) -> ParsedResponsePayload {
        let outputText = joinedUnique(stringsFromOutput(in: jsonObject))
        let thoughts = normalize(joinedUnique(stringsFromReasoning(in: jsonObject)))
        return ParsedResponsePayload(outputText: outputText, thoughts: thoughts)
    }

    static func parseStreamingEvent(data: Data, eventName: String?) -> [ParsedStreamingPayload] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let loweredEvent = (eventName ?? eventType(in: json) ?? "").lowercased()
        var events: [ParsedStreamingPayload] = []

        if loweredEvent.contains("completed") || loweredEvent.contains("done") {
            let parsed = parseResponse(jsonObject: json)
            events.append(.completed(finalText: normalize(parsed.outputText), thoughts: parsed.thoughts))
            return events
        }

        if loweredEvent.contains("reasoning") || loweredEvent.contains("thinking") {
            joinedUnique(deltaStrings(in: json, preferReasoning: true))
                .nonEmpty
                .map { events.append(.thoughtsDelta($0)) }
            return events
        }

        if loweredEvent.contains("output_text") || loweredEvent.contains("message") || loweredEvent.contains("content") {
            joinedUnique(deltaStrings(in: json, preferReasoning: false))
                .nonEmpty
                .map { events.append(.outputDelta($0)) }
            return events
        }

        if let type = nestedTypeMarker(in: json), type.contains("reasoning") {
            joinedUnique(deltaStrings(in: json, preferReasoning: true))
                .nonEmpty
                .map { events.append(.thoughtsDelta($0)) }
        } else if let type = nestedTypeMarker(in: json), type.contains("message") || type.contains("output_text") {
            joinedUnique(deltaStrings(in: json, preferReasoning: false))
                .nonEmpty
                .map { events.append(.outputDelta($0)) }
        } else {
            joinedUnique(deltaStrings(in: json, preferReasoning: true))
                .nonEmpty
                .map { events.append(.thoughtsDelta($0)) }
            joinedUnique(deltaStrings(in: json, preferReasoning: false))
                .nonEmpty
                .map { events.append(.outputDelta($0)) }
        }

        return events
    }

    private static func eventType(in json: Any) -> String? {
        guard let dictionary = json as? [String: Any] else { return nil }
        return firstString(forKeys: ["type", "event"], in: dictionary)
    }

    private static func nestedTypeMarker(in json: Any) -> String? {
        guard let dictionary = json as? [String: Any] else { return nil }
        if let item = dictionary["item"] as? [String: Any] {
            return (item["type"] as? String)?.lowercased()
        }
        if let delta = dictionary["delta"] as? [String: Any] {
            return (delta["type"] as? String)?.lowercased()
        }
        return nil
    }

    private static func stringsFromOutput(in value: Any) -> [String] {
        walk(value, currentHint: nil) { string, hint in
            guard let hint else { return false }
            return hint == .output
        }
    }

    private static func stringsFromReasoning(in value: Any) -> [String] {
        walk(value, currentHint: nil) { _, hint in
            hint == .reasoning
        }
    }

    private static func deltaStrings(in value: Any, preferReasoning: Bool) -> [String] {
        walk(value, currentHint: nil) { string, hint in
            if preferReasoning {
                return hint == .reasoning && !string.isEmpty
            }
            return hint == .output && !string.isEmpty
        }
    }

    private enum ContentHint {
        case reasoning
        case output
    }

    private static func walk(
        _ value: Any,
        currentHint: ContentHint?,
        shouldCollect: (_ string: String, _ hint: ContentHint?) -> Bool
    ) -> [String] {
        var results: [String] = []

        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if shouldCollect(trimmed, currentHint) {
                results.append(trimmed)
            }
            return results
        }

        if let array = value as? [Any] {
            for item in array {
                results.append(contentsOf: walk(item, currentHint: currentHint, shouldCollect: shouldCollect))
            }
            return results
        }

        guard let dictionary = value as? [String: Any] else {
            return results
        }

        let nextHint = inferredHint(from: dictionary) ?? currentHint

        for (key, nestedValue) in dictionary {
            let loweredKey = key.lowercased()

            if loweredKey == "delta" || loweredKey == "text" || loweredKey == "output_text" || loweredKey == "content" || loweredKey == "summary" {
                results.append(contentsOf: walk(nestedValue, currentHint: nextHint, shouldCollect: shouldCollect))
                continue
            }

            if loweredKey == "reasoning" {
                results.append(contentsOf: walk(nestedValue, currentHint: .reasoning, shouldCollect: shouldCollect))
                continue
            }

            results.append(contentsOf: walk(nestedValue, currentHint: nextHint, shouldCollect: shouldCollect))
        }

        return results
    }

    private static func inferredHint(from dictionary: [String: Any]) -> ContentHint? {
        let type = firstString(forKeys: ["type", "event"], in: dictionary)?.lowercased() ?? ""
        if type.contains("reasoning") || type.contains("thinking") {
            return .reasoning
        }
        if type.contains("message") || type.contains("output_text") || type.contains("content") {
            return .output
        }

        if dictionary.keys.map({ $0.lowercased() }).contains("reasoning") {
            return .reasoning
        }
        if dictionary.keys.map({ $0.lowercased() }).contains("output_text") {
            return .output
        }
        return nil
    }

    private static func firstString(forKeys keys: [String], in dictionary: [String: Any]) -> String? {
        for key in keys {
            if let string = dictionary[key] as? String, !string.isEmpty {
                return string
            }
        }
        return nil
    }

    private static func joinedUnique(_ strings: [String]) -> String {
        var seen = Set<String>()
        return strings
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
            .joined()
    }

    private static func normalize(_ string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : self
    }
}
