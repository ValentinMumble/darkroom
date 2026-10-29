import Foundation
import SQLite3
import Testing

@testable import Freedown

/// The query on a small database shaped like Photos' own
struct RecentlyDeletedTests {
    private func database(_ statements: [String]) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appending(path: "freedown-test-\(UUID().uuidString).sqlite")
        var connection: OpaquePointer?
        guard sqlite3_open(file.path, &connection) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(connection) }
        for statement in statements {
            guard sqlite3_exec(connection, statement, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        }
        return file
    }

    @Test func countsDeletedItemsAndWhatICloudStoresForThem() throws {
        let deleted = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let file = try database([
            "CREATE TABLE ZASSET (Z_PK INTEGER, ZTRASHEDSTATE INTEGER, ZTRASHEDDATE REAL)",
            "CREATE TABLE ZINTERNALRESOURCE (ZASSET INTEGER, ZRESOURCETYPE INTEGER, ZRECIPEID INTEGER, ZDATALENGTH INTEGER)",
            "INSERT INTO ZASSET VALUES (1, 1, \(deleted.timeIntervalSinceReferenceDate)), (2, 1, \(deleted.timeIntervalSinceReferenceDate + 86_400)), (3, 0, NULL)",
            // Item 1: original 100 and motion 50, a preview Photos can make again, an edited version 30
            "INSERT INTO ZINTERNALRESOURCE VALUES (1, 0, 0, 100), (1, 3, 0, 50), (1, 0, 65741, 999), (1, 0, 65938, 30)",
            "INSERT INTO ZINTERNALRESOURCE VALUES (2, 1, 0, 1000), (3, 0, 0, 7777)",
        ])
        defer { try? FileManager.default.removeItem(at: file) }
        let trash = try RecentlyDeleted.read(file).get()
        #expect(trash.count == 2)
        #expect(trash.size == 1180)
        #expect(trash.firstPurge == deleted.addingTimeInterval(30 * 24 * 3600))
    }

    @Test func noLibraryIsUnreadable() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "no-such-library.sqlite")
        guard case .failure(.unreadable) = RecentlyDeleted.read(missing) else {
            Issue.record("expected unreadable")
            return
        }
    }
}
