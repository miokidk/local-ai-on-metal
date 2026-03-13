import Foundation

enum ReasoningEffort: String, Codable, CaseIterable, Identifiable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var title: String {
        rawValue.capitalized
    }
}

struct AppSettings: Codable, Equatable {
    static let defaultBaseURL = "http://127.0.0.1:11434/v1"
    static let defaultModelName = "gpt-oss"

    var baseURLString: String = AppSettings.defaultBaseURL
    var defaultModel: String = AppSettings.defaultModelName
    var selectedModel: String = AppSettings.defaultModelName
    var recentModels: [String] = [AppSettings.defaultModelName]
    var selectedReasoningEffort: ReasoningEffort = .medium
    var autoShowThoughts: Bool = true
    var apiKey: String = ""

    var resolvedBaseURL: URL? {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: trimmed)
    }

    var sanitizedRecentModels: [String] {
        let source = recentModels + [selectedModel, defaultModel]
        var seen = Set<String>()
        return source
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    mutating func registerModel(_ model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        selectedModel = trimmed
        if !recentModels.contains(trimmed) {
            recentModels.insert(trimmed, at: 0)
        }
        recentModels = Array(recentModels.prefix(12))
    }
}
