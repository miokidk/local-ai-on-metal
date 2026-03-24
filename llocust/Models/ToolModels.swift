import Foundation

struct ResponseFunctionToolDefinition {
    let name: String
    let description: String
    let parameters: [String: Any]
    let strict: Bool

    init(
        name: String,
        description: String,
        parameters: [String: Any],
        strict: Bool = false
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.strict = strict
    }

    var payload: [String: Any] {
        var payload: [String: Any] = [
            "type": "function",
            "name": name,
            "description": description,
            "parameters": parameters
        ]

        if strict {
            payload["strict"] = true
        }

        return payload
    }
}

struct ParsedResponseToolCall {
    let name: String
    let callID: String
    let argumentsJSON: String
}
