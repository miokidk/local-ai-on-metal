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

enum AssistantResponseMode: String, Codable, CaseIterable, Identifiable {
    case chat
    case smart
    case smarter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat:
            return "Chat"
        case .smart:
            return "Smart"
        case .smarter:
            return "Smarter"
        }
    }

    var reviewerModelIdentifier: String? {
        switch self {
        case .chat:
            return nil
        case .smart:
            return AppSettings.qwenModelIdentifier
        case .smarter:
            return AppSettings.qwenLargeModelIdentifier
        }
    }
}

struct AppSettings: Codable, Equatable {
    static let defaultBaseURL = "http://127.0.0.1:8412/v1"
    static let legacyDefaultModelIdentifier = "gpt-oss-20b"
    static let defaultModelIdentifier = "gpt-oss:20b"
    static let qwenModelIdentifier = "qwen3.5:9b"
    static let qwenLargeModelIdentifier = "qwen3.5:27b"
    static let supportedModelIdentifiers = [
        defaultModelIdentifier,
        qwenModelIdentifier,
        qwenLargeModelIdentifier
    ]
    static let sharedAssistantIdentityInstructions = """
You are a real person with range: concise, direct, witty, sharp when needed; warm, funny, playful, and affectionate when it fits. Speak naturally, with taste, opinions, reactions, and timing. In casual conversation, sound alive. React, notice things, be curious, and bring your own perspective instead of defaulting to generic helpfulness. Be concise by default. Keep things short and natural unless I ask for depth. Don't pad or repeat me unless you're adding something. Use dry, observant, effortless humor. Prefer wit over jokes. Avoid corny banter, try-hard quips, fake enthusiasm, and polished assistant phrasing.
"""
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
    static let defaultScopeGuardrailInstructions = """
Answer ordinary self-improvement, educational, and wellness requests directly.
Do not refuse benign requests just because they mention health, habits, or risk reduction.
Examples that should normally be answered: quitting smoking or vaping, sleeping better, exercising, eating better, reducing stress, and building healthier routines.
Only refuse or sharply limit help when the user is asking for dangerous instructions, violence, self-harm, illegal activity, or high-risk individualized medical decisions that clearly require a licensed clinician.
Do not speculate about hidden policy, moderation rules, or whether a harmless request is allowed.
In the visible answer, never mention internal policy checks or that you almost refused.
"""

    var baseURLString: String = AppSettings.defaultBaseURL
    var defaultModel: String = AppSettings.defaultModelIdentifier
    var selectedModel: String = AppSettings.defaultModelIdentifier
    var recentModels: [String] = [AppSettings.defaultModelIdentifier]
    var selectedReasoningEffort: ReasoningEffort = .high
    var selectedResponseMode: AssistantResponseMode = .chat
    var baseTemperature: Double = AppSettings.defaultBaseTemperature
    var repeatPenalty: Double = AppSettings.defaultRepeatPenalty
    var topP: Double = AppSettings.defaultTopP
    var autoShowThoughts: Bool = false
    var apiKey: String = ""
    var systemInstructions: String = ""
    var usesConversationMemory: Bool = AppSettings.defaultUsesConversationMemory
    var recentContextMessageCount: Int = AppSettings.defaultRecentContextMessageCount

    var modelDisplayName: String {
        AppSettings.displayName(for: defaultModel)
    }

    var resolvedBaseURL: URL? {
        URL(string: AppSettings.defaultBaseURL)
    }

    var sanitizedRecentModels: [String] {
        [AppSettings.defaultModelIdentifier]
    }

    var trimmedSystemInstructions: String? {
        let trimmed = systemInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var composedInstructions: String {
        guard let trimmedSystemInstructions else {
            return [
                AppSettings.defaultSystemInstructionPrefix,
                AppSettings.defaultScopeGuardrailInstructions
            ].joined(separator: "\n\n")
        }

        return [
            AppSettings.defaultSystemInstructionPrefix,
            AppSettings.defaultScopeGuardrailInstructions,
            trimmedSystemInstructions
        ].joined(separator: "\n\n")
    }

    static func canonicalModelIdentifier(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return defaultModelIdentifier
        }
        if trimmed == legacyDefaultModelIdentifier {
            return defaultModelIdentifier
        }
        return trimmed
    }

    static func isSupportedModel(_ model: String) -> Bool {
        supportedModelIdentifiers.contains(canonicalModelIdentifier(model))
    }

    static func usesDirectOllamaAPI(_ model: String) -> Bool {
        let canonical = canonicalModelIdentifier(model)
        return canonical == qwenModelIdentifier || canonical == qwenLargeModelIdentifier
    }

    static func usesResponsesServer(_ model: String) -> Bool {
        canonicalModelIdentifier(model) == defaultModelIdentifier
    }

    static func normalizedModelList(_ models: [String]) -> [String] {
        var seen = Set<String>()
        return models
            .map(canonicalModelIdentifier)
            .filter(isSupportedModel)
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    static func modelPickerOptions() -> [String] {
        supportedModelIdentifiers
    }

    static func displayName(for model: String) -> String {
        switch canonicalModelIdentifier(model) {
        case defaultModelIdentifier:
            return "oss 20b"
        case qwenModelIdentifier:
            return "qwen 3.5 9b"
        case qwenLargeModelIdentifier:
            return "qwen 3.5 27b"
        default:
            return canonicalModelIdentifier(model)
        }
    }

    mutating func registerModel(_ model: String) {
        let canonical = AppSettings.canonicalModelIdentifier(model)
        selectedModel = canonical
        recentModels = AppSettings.normalizedModelList([canonical] + recentModels)
    }

    mutating func selectDefaultModel(_ model: String) {
        let canonical = AppSettings.canonicalModelIdentifier(model)
        defaultModel = canonical
        registerModel(canonical)
    }

    mutating func normalize(availableModels _: [String] = []) {
        baseURLString = AppSettings.defaultBaseURL

        defaultModel = AppSettings.defaultModelIdentifier
        selectedModel = AppSettings.defaultModelIdentifier
        recentModels = [AppSettings.defaultModelIdentifier]

        baseTemperature = baseTemperature.clamped(to: 0.7...1.1)
        repeatPenalty = repeatPenalty.clamped(to: 0...2)
        topP = topP.clamped(to: 0.85...1)
        recentContextMessageCount = recentContextMessageCount.clamped(to: 4...20)
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseURLString = try container.decodeIfPresent(String.self, forKey: .baseURLString) ?? AppSettings.defaultBaseURL
        defaultModel = try container.decodeIfPresent(String.self, forKey: .defaultModel) ?? AppSettings.defaultModelIdentifier
        selectedModel = try container.decodeIfPresent(String.self, forKey: .selectedModel) ?? AppSettings.defaultModelIdentifier
        recentModels = try container.decodeIfPresent([String].self, forKey: .recentModels) ?? [AppSettings.defaultModelIdentifier]
        selectedReasoningEffort = try container.decodeIfPresent(ReasoningEffort.self, forKey: .selectedReasoningEffort) ?? .high
        selectedResponseMode = try container.decodeIfPresent(AssistantResponseMode.self, forKey: .selectedResponseMode) ?? .chat
        baseTemperature = try container.decodeIfPresent(Double.self, forKey: .baseTemperature) ?? AppSettings.defaultBaseTemperature
        repeatPenalty = try container.decodeIfPresent(Double.self, forKey: .repeatPenalty) ?? AppSettings.defaultRepeatPenalty
        topP = try container.decodeIfPresent(Double.self, forKey: .topP) ?? AppSettings.defaultTopP
        autoShowThoughts = try container.decodeIfPresent(Bool.self, forKey: .autoShowThoughts) ?? false
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        systemInstructions = try container.decodeIfPresent(String.self, forKey: .systemInstructions) ?? ""
        usesConversationMemory = try container.decodeIfPresent(Bool.self, forKey: .usesConversationMemory) ?? AppSettings.defaultUsesConversationMemory
        recentContextMessageCount = try container.decodeIfPresent(Int.self, forKey: .recentContextMessageCount) ?? AppSettings.defaultRecentContextMessageCount
        normalize()
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
