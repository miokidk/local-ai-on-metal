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
        let responseObject = rootResponseObject(from: jsonObject)
        let outputText = assistantOutputText(in: responseObject)
        let thoughts = normalize(reasoningText(in: responseObject))
        return ParsedResponsePayload(outputText: outputText, thoughts: thoughts)
    }

    static func parseStreamingEvent(data: Data, eventName: String?) -> [ParsedStreamingPayload] {
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let dictionary = json as? [String: Any] else {
            return []
        }

        let loweredEvent = (eventName ?? eventType(in: dictionary) ?? "").lowercased()

        switch loweredEvent {
        case "response.reasoning_text.delta", "response.reasoning_summary_text.delta":
            return stringValue(forKey: "delta", in: dictionary).nonEmpty.map { [.thoughtsDelta($0)] } ?? []
        case "response.output_text.delta":
            return stringValue(forKey: "delta", in: dictionary).nonEmpty.map { [.outputDelta($0)] } ?? []
        case "response.reasoning_text.done":
            return stringValue(forKey: "text", in: dictionary).nonEmpty.map { [.completed(finalText: nil, thoughts: $0)] } ?? []
        case "response.output_text.done":
            return stringValue(forKey: "text", in: dictionary).nonEmpty.map { [.completed(finalText: $0, thoughts: nil)] } ?? []
        case "response.completed":
            let parsed = parseResponse(jsonObject: dictionary["response"] ?? dictionary)
            return [.completed(finalText: normalize(parsed.outputText), thoughts: parsed.thoughts)]
        default:
            return []
        }
    }

    private static func rootResponseObject(from jsonObject: Any) -> Any {
        guard let dictionary = jsonObject as? [String: Any],
              let response = dictionary["response"] else {
            return jsonObject
        }

        return response
    }

    private static func assistantOutputText(in jsonObject: Any) -> String {
        guard let dictionary = jsonObject as? [String: Any],
              let output = dictionary["output"] as? [[String: Any]] else {
            return ""
        }

        var text = ""

        for item in output where (item["type"] as? String) == "message" {
            let role = (item["role"] as? String)?.lowercased()
            guard role == "assistant",
                  let content = item["content"] as? [[String: Any]] else {
                continue
            }

            for part in content {
                let type = (part["type"] as? String)?.lowercased()
                guard type == "output_text" || type == "text" || type == "input_text" else {
                    continue
                }

                text += stringValue(forKey: "text", in: part)
            }
        }

        return text
    }

    private static func reasoningText(in jsonObject: Any) -> String {
        guard let dictionary = jsonObject as? [String: Any],
              let output = dictionary["output"] as? [[String: Any]] else {
            return ""
        }

        var text = ""

        for item in output where (item["type"] as? String) == "reasoning" {
            if let content = item["content"] as? [[String: Any]] {
                for part in content where (part["type"] as? String)?.lowercased() == "reasoning_text" {
                    text += stringValue(forKey: "text", in: part)
                }
            }

            if let summary = item["summary"] as? [[String: Any]] {
                for part in summary where (part["type"] as? String)?.lowercased() == "summary_text" {
                    text += stringValue(forKey: "text", in: part)
                }
            }
        }

        return text
    }

    private static func eventType(in dictionary: [String: Any]) -> String? {
        stringValue(forKey: "type", in: dictionary).nonEmpty
            ?? stringValue(forKey: "event", in: dictionary).nonEmpty
    }

    private static func stringValue(forKey key: String, in dictionary: [String: Any]) -> String {
        guard let string = dictionary[key] as? String else { return "" }
        return string
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
