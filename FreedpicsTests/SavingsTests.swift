import Foundation
import Testing

@testable import Freedpics

struct SavingsTests {
    /// The same encoding as the savings file, a correction entry included
    @Test func entriesSurviveTheFile() throws {
        let entries = [
            Saving(date: Date(timeIntervalSince1970: 1_800_000_000), kind: .removedMotion, count: 720, bytes: 2_705_152_643),
            Saving(date: Date(timeIntervalSince1970: 1_800_000_100), kind: .removedMotion, count: -720, bytes: -2_705_152_643),
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([Saving].self, from: encoder.encode(entries))
        #expect(decoded.map(\.bytes) == entries.map(\.bytes))
        #expect(decoded.reduce(0) { $0 + $1.bytes } == 0)
        #expect(decoded.first?.date == entries.first?.date)
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// A correction on the same day cancels what it corrects, and kinds come in their fixed order
    @Test func daysAddUpByKind() {
        let morning = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = [
            Saving(date: morning, kind: .shrunk, count: 2, bytes: 500),
            Saving(date: morning, kind: .removedMotion, count: 3, bytes: 300),
            Saving(date: morning.addingTimeInterval(60), kind: .removedMotion, count: -1, bytes: -100),
            Saving(date: morning.addingTimeInterval(86_400), kind: .deleted, count: 1, bytes: 40),
        ]
        let days = Savings.daily(entries, calendar: Self.utc)
        #expect(days.map(\.kind) == [.removedMotion, .shrunk, .deleted])
        #expect(days.map(\.bytes) == [200, 500, 40])
        #expect(days[0].day == Self.utc.startOfDay(for: morning))
    }

    @Test func readingsAreAnHourApart() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var readings = StorageHistory.adding(100, at: start, to: [])
        readings = StorageHistory.adding(200, at: start.addingTimeInterval(1_800), to: readings)
        #expect(readings.map(\.free) == [100])
        readings = StorageHistory.adding(300, at: start.addingTimeInterval(3_600), to: readings)
        #expect(readings.map(\.free) == [100, 300])
    }

    /// Only what was counted between the first and last readings is set against iCloud's change
    @Test func comparisonCoversTheReadings() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let readings = [StorageReading(date: start, free: 1_000), StorageReading(date: start.addingTimeInterval(7_200), free: 1_600)]
        let entries = [
            Saving(date: start.addingTimeInterval(-60), kind: .deleted, count: 1, bytes: 999),
            Saving(date: start.addingTimeInterval(60), kind: .shrunk, count: 1, bytes: 500),
        ]
        let comparison = try #require(Savings.comparison(entries, readings))
        #expect(comparison.freed == 600)
        #expect(comparison.counted == 500)
        #expect(Savings.comparison(entries, Array(readings.prefix(1))) == nil)
    }
}
