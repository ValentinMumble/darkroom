import Foundation
import Testing

@testable import Freedpics

/// The scan on a small folder shaped like ~/Library/Mobile Documents
struct ICloudDriveTests {
    @Test func listsBigFilesWithWhereTheyAreAndWhoKeepsThem() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "freedpics-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ path: String, megabytes: Double) throws {
            let file = root.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: Int(megabytes * 1_048_576)).write(to: file)
        }
        try write("com~apple~CloudDocs/Manuals/Lego/x-wing.pdf", megabytes: 3)
        try write("com~apple~CloudDocs/notes.txt", megabytes: 0.01)
        try write("com~apple~CloudDocs/backup.zip", megabytes: 2)
        try write("X~com~example~Notes/Documents/Trips/map.pdf", megabytes: 1.5)
        try write("X~com~example~Chat/Accounts/backup/Media.tar", megabytes: 4)

        let files = ICloudDrive.scan(root)
        #expect(files.map(\.name) == ["Media.tar", "x-wing.pdf", "backup.zip", "map.pdf"])
        #expect(files.map(\.place) == ["X~com~example~Chat", "iCloud Drive › Manuals › Lego", "iCloud Drive", "X~com~example~Notes › Trips"])
        // Only data an app keeps outside its Documents folder is the app's own
        #expect(files.map { $0.keptBy != nil } == [true, false, false, false])
        #expect(files[1].size == 3 * 1_048_576)
    }
}
