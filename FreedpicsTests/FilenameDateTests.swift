import Foundation
import Testing

@testable import Freedpics

struct FilenameDateTests {
    @Test func readsTheDateInAFileName() throws {
        let date = try #require(FilenameDate.parse("IMG_20240714_183000.jpg", pattern: "%Y%m%d_%H%M%S"))
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        #expect(parts == DateComponents(year: 2024, month: 7, day: 14, hour: 18, minute: 30, second: 0))
    }

    @Test func aDateWithoutATimeStartsTheDay() throws {
        let date = try #require(FilenameDate.parse("Scan 2019-03-02.jpg", pattern: "%Y-%m-%d"))
        #expect(Calendar.current.dateComponents([.hour, .minute], from: date) == DateComponents(hour: 0, minute: 0))
    }

    @Test func noMatchGivesNothing() {
        #expect(FilenameDate.parse("IMG_0001.HEIC", pattern: "%Y%m%d_%H%M%S") == nil)
    }
}
