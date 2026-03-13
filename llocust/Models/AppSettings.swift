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
    static let defaultBaseURL = "http://127.0.0.1:8412/v1"
    static let fixedModelIdentifier = "gpt-oss-20b"
    static let fixedModelName = "oss 20b Metal"

    var baseURLString: String = AppSettings.defaultBaseURL
    var defaultModel: String = AppSettings.fixedModelIdentifier
    var selectedModel: String = AppSettings.fixedModelIdentifier
    var recentModels: [String] = [AppSettings.fixedModelIdentifier]
    var selectedReasoningEffort: ReasoningEffort = .medium
    var autoShowThoughts: Bool = false
    var apiKey: String = ""
    var systemInstructions: String = ""

    var modelDisplayName: String {
        AppSettings.fixedModelName
    }

    var resolvedBaseURL: URL? {
        URL(string: AppSettings.defaultBaseURL)
    }

    var sanitizedRecentModels: [String] {
        let source = recentModels + [selectedModel, defaultModel]
        var seen = Set<String>()
        return source
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    var trimmedSystemInstructions: String? {
        let trimmed = systemInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    mutating func registerModel(_ model: String) {
        _ = model
        selectedModel = AppSettings.fixedModelIdentifier
        defaultModel = AppSettings.fixedModelIdentifier
        recentModels = [AppSettings.fixedModelIdentifier]
    }

    mutating func normalizeForSingleModel() {
        baseURLString = AppSettings.defaultBaseURL
        registerModel(AppSettings.fixedModelIdentifier)
    }
}
