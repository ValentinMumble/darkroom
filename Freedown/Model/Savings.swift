import Foundation

/// Space one change made with Freedown freed. Saved, so the total survives across launches.
struct Saving: Codable {
    enum Kind: String, Codable, CaseIterable {
        case deleted, removedMotion, keptEdit, shrunk, convertedToHEIC, deletedFiles

        var label: String {
            switch self {
            case .deleted: "Deleted"
            case .removedMotion: "Motion removed"
            case .keptEdit: "Edited version kept"
            case .shrunk: "Shrunk"
            case .convertedToHEIC: "Converted to HEIC"
            case .deletedFiles: "Deleted from iCloud Drive"
            }
        }

        var noun: String {
            switch self {
            case .removedMotion: "Live Photo"
            case .shrunk: "video"
            case .convertedToHEIC: "photo"
            case .deletedFiles: "file"
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
    private static let file = "savings.json"

    static func load() -> [Saving] {
        Settings.read([Saving].self, from: file) ?? []
    }

    static func save(_ savings: [Saving]) {
        Settings.write(savings, to: file)
    }
}

extension Savings {
    /// What one day saved with one kind of change
    struct Day: Identifiable {
        let day: Date
        let kind: Saving.Kind
        let bytes: Int64
        var id: String { "\(day.timeIntervalSince1970)-\(kind.rawValue)" }
    }

    /// The savings added up by day and kind, in day then kind order
    static func daily(_ savings: [Saving], calendar: Calendar = .current) -> [Day] {
        let grouped = Dictionary(grouping: savings) { DayKind(day: calendar.startOfDay(for: $0.date), kind: $0.kind) }
        return grouped.map { key, entries in Day(day: key.day, kind: key.kind, bytes: entries.reduce(0) { $0 + $1.bytes }) }
            .sorted {
                ($0.day, Saving.Kind.allCases.firstIndex(of: $0.kind)!) < ($1.day, Saving.Kind.allCases.firstIndex(of: $1.kind)!)
            }
    }

    private struct DayKind: Hashable {
        let day: Date
        let kind: Saving.Kind
    }

    /// iCloud's free space from the first reading to the last, against what Freedown counted in that time
    struct Comparison {
        let since: Date
        let freed: Int64
        let counted: Int64
    }

    static func comparison(_ savings: [Saving], _ readings: [StorageReading]) -> Comparison? {
        guard let first = readings.first, let last = readings.last, last.date > first.date else { return nil }
        let counted = savings.filter { $0.date >= first.date && $0.date <= last.date }.reduce(0) { $0 + $1.bytes }
        return Comparison(since: first.date, freed: last.free - first.free, counted: counted)
    }
}

/// iCloud's free space at one time
struct StorageReading: Codable {
    let date: Date
    let free: Int64
}

/// iCloud's free space over time, read at most once an hour, so what Freedown counted can be set against
/// what iCloud really freed. iCloud's free space also moves with everything else in it: backups, other apps,
/// new photos.
enum StorageHistory {
    private static let file = "icloud-free.json"
    static let interval: TimeInterval = 3600

    static func load() -> [StorageReading] {
        Settings.read([StorageReading].self, from: file) ?? []
    }

    /// The readings with this one added, unless the last one is less than an hour old
    static func adding(_ free: Int64, at date: Date = .now, to readings: [StorageReading]) -> [StorageReading] {
        if let last = readings.last, date.timeIntervalSince(last.date) < interval { return readings }
        return readings + [StorageReading(date: date, free: free)]
    }

    static func save(_ readings: [StorageReading]) {
        Settings.write(readings, to: file)
    }
}
