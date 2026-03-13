import Foundation

actor ChatPersistence {
    private let fileManager = FileManager.default
    private let appDirectoryName = "OssChat"
    private let stateFileName = "Chats.json"

    private var stateURL: URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        let directoryURL = baseURL.appendingPathComponent(appDirectoryName, isDirectory: true)
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        return directoryURL.appendingPathComponent(stateFileName)
    }

    func load() -> PersistedChatState? {
        let url = stateURL
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(PersistedChatState.self, from: data)
        } catch {
            return nil
        }
    }

    func save(_ state: PersistedChatState) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(state)
            try data.write(to: stateURL, options: .atomic)
        } catch {
            assertionFailure("Failed to save chats: \(error)")
        }
    }
}
