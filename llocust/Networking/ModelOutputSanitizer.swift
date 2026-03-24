import Foundation

enum ModelOutputSanitizer {
    private static let trailingControlTokenPattern = try! NSRegularExpression(
        pattern: #"[ \t\r\n]*<\|([A-Za-z0-9_:-]{1,64})\|>[ \t\r\n]*$"#
    )

    private static let trailingPartialControlTokenPattern = try! NSRegularExpression(
        pattern: #"<\|([A-Za-z0-9_:-]{0,64})$"#
    )

    private static let knownExactTokenNames: Set<String> = [
        "startoftext",
        "endoftext",
        "start",
        "end",
        "message",
        "channel",
        "return",
        "constrain",
        "call"
    ]

    private static let knownTokenPrefixes = [
        "reserved_",
        "vq_"
    ]

    private static let suppressedThoughtSignals = [
        "according to policy",
        "policy says",
        "disallowed content",
        "medical advice is disallowed",
        "we must refuse",
        "we should refuse",
        "output a refusal",
        "hence output a refusal",
        "double-check:",
        "the assistant should not provide"
    ]

    static func sanitize(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        var sanitized = text

        while true {
            let updated = removingTrailingArtifact(from: sanitized)
            if updated == sanitized {
                return sanitized
            }
            sanitized = updated
        }
    }

    static func sanitizeThoughts(_ text: String) -> String {
        let sanitized = sanitize(text)
        guard !shouldSuppressThoughtTrace(sanitized) else {
            return ""
        }

        return sanitized
    }

    private static func removingTrailingArtifact(from text: String) -> String {
        let fullRange = NSRange(text.startIndex..., in: text)

        if let match = trailingControlTokenPattern.firstMatch(in: text, range: fullRange),
           let nameRange = Range(match.range(at: 1), in: text),
           isLikelyControlTokenName(String(text[nameRange])),
           let matchRange = Range(match.range, in: text) {
            return String(text[..<matchRange.lowerBound])
        }

        if let match = trailingPartialControlTokenPattern.firstMatch(in: text, range: fullRange),
           let fragmentRange = Range(match.range(at: 1), in: text),
           isLikelyControlTokenPrefix(String(text[fragmentRange])),
           let matchRange = Range(match.range, in: text) {
            return String(text[..<matchRange.lowerBound])
        }

        return text
    }

    private static func isLikelyControlTokenName(_ tokenName: String) -> Bool {
        let lowered = tokenName.lowercased()

        if knownExactTokenNames.contains(lowered) {
            return true
        }

        if knownTokenPrefixes.contains(where: { lowered.hasPrefix($0) }) {
            return true
        }

        return lowered.range(of: #"^[a-z]{1,6}_[0-9]{2,8}$"#, options: .regularExpression) != nil
    }

    private static func isLikelyControlTokenPrefix(_ tokenFragment: String) -> Bool {
        let lowered = tokenFragment.lowercased()

        if lowered.isEmpty || knownExactTokenNames.contains(lowered) {
            return true
        }

        if knownTokenPrefixes.contains(where: { lowered.hasPrefix($0) || $0.hasPrefix(lowered) }) {
            return true
        }

        return lowered.range(of: #"^[a-z]{0,6}(?:_[0-9]{0,8})?$"#, options: .regularExpression) != nil
    }

    private static func shouldSuppressThoughtTrace(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let matchCount = suppressedThoughtSignals.reduce(into: 0) { partialResult, signal in
            if lowered.contains(signal) {
                partialResult += 1
            }
        }

        if matchCount >= 2 {
            return true
        }

        return lowered.hasPrefix("the user asks:") && matchCount >= 1
    }
}
