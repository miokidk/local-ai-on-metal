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
    static let fixedModelName = "oss 20b"
    static let defaultBaseTemperature = 0.92
    static let defaultRepeatPenalty = 0.4
    static let defaultTopP = 0.96
    static let defaultUsesConversationMemory = true
    static let defaultRecentContextMessageCount = 10
    static let defaultSystemInstructionPrefix = """
You may reason as deeply and freely as needed.
When a prompt is underspecified, make one reasonable interpretation and proceed unless clarification is truly necessary.
Once you have a viable direction, carry it through instead of repeatedly restarting, restating the task, narrating self-corrections, or comparing multiple possible approaches at length.
Do not spend analysis on apologies, process commentary, or announcing that you will restart.
If you notice yourself looping, use that as a cue to commit to the best current continuation and keep moving.
"""

    var baseURLString: String = AppSettings.defaultBaseURL
    var defaultModel: String = AppSettings.fixedModelIdentifier
    var selectedModel: String = AppSettings.fixedModelIdentifier
    var recentModels: [String] = [AppSettings.fixedModelIdentifier]
    var selectedReasoningEffort: ReasoningEffort = .high
    var baseTemperature: Double = AppSettings.defaultBaseTemperature
    var repeatPenalty: Double = AppSettings.defaultRepeatPenalty
    var topP: Double = AppSettings.defaultTopP
    var autoShowThoughts: Bool = false
    var apiKey: String = ""
    var systemInstructions: String = ""
    var usesConversationMemory: Bool = AppSettings.defaultUsesConversationMemory
    var recentContextMessageCount: Int = AppSettings.defaultRecentContextMessageCount

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

    var composedInstructions: String {
        guard let trimmedSystemInstructions else {
            return AppSettings.defaultSystemInstructionPrefix
        }

        return [
            AppSettings.defaultSystemInstructionPrefix,
            trimmedSystemInstructions
        ].joined(separator: "\n\n")
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
        baseTemperature = baseTemperature.clamped(to: 0.7...1.1)
        repeatPenalty = repeatPenalty.clamped(to: 0...2)
        topP = topP.clamped(to: 0.85...1)
        recentContextMessageCount = recentContextMessageCount.clamped(to: 4...20)
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseURLString = try container.decodeIfPresent(String.self, forKey: .baseURLString) ?? AppSettings.defaultBaseURL
        defaultModel = try container.decodeIfPresent(String.self, forKey: .defaultModel) ?? AppSettings.fixedModelIdentifier
        selectedModel = try container.decodeIfPresent(String.self, forKey: .selectedModel) ?? AppSettings.fixedModelIdentifier
        recentModels = try container.decodeIfPresent([String].self, forKey: .recentModels) ?? [AppSettings.fixedModelIdentifier]
        selectedReasoningEffort = try container.decodeIfPresent(ReasoningEffort.self, forKey: .selectedReasoningEffort) ?? .high
        baseTemperature = try container.decodeIfPresent(Double.self, forKey: .baseTemperature) ?? AppSettings.defaultBaseTemperature
        repeatPenalty = try container.decodeIfPresent(Double.self, forKey: .repeatPenalty) ?? AppSettings.defaultRepeatPenalty
        topP = try container.decodeIfPresent(Double.self, forKey: .topP) ?? AppSettings.defaultTopP
        autoShowThoughts = try container.decodeIfPresent(Bool.self, forKey: .autoShowThoughts) ?? false
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        systemInstructions = try container.decodeIfPresent(String.self, forKey: .systemInstructions) ?? ""
        usesConversationMemory = try container.decodeIfPresent(Bool.self, forKey: .usesConversationMemory) ?? AppSettings.defaultUsesConversationMemory
        recentContextMessageCount = try container.decodeIfPresent(Int.self, forKey: .recentContextMessageCount) ?? AppSettings.defaultRecentContextMessageCount
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
