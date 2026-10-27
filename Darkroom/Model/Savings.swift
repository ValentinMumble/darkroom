import Foundation

/// Space one change made with Darkroom freed. Saved, so the total survives across launches.
struct Saving: Codable {
    enum Kind: String, Codable, CaseIterable {
        case deleted, removedMotion, keptEdit, shrunk

        var label: String {
            switch self {
            case .deleted: "Deleted"
            case .removedMotion: "Motion removed"
            case .keptEdit: "Edited version kept"
            case .shrunk: "Shrunk"
            }
        }

        var noun: String {
            switch self {
            case .removedMotion: "Live Photo"
            case .shrunk: "video"
            case .deleted, .keptEdit: "item"
            }
        }
    }

    let date: Date
    let kind: Kind
    let count: Int
    let bytes: Int64
}

enum Savings {
    private static let file = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Darkroom/savings.json")

    static func load() -> [Saving] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Saving].self, from: data)) ?? []
    }

    static func save(_ savings: [Saving]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(savings).write(to: file)
    }
}
