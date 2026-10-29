import Foundation
import SQLite3

/// Recently Deleted, read from Photos' own database: PhotoKit never shows deleted items to other apps, even
/// through its private options. macOS lets an app open that database only with Full Disk Access.
struct RecentlyDeleted {
    enum Failure: Error {
        case noAccess
        /// No library where expected, or a database this app does not understand
        case unreadable
    }

    let count: Int
    /// What iCloud stores for them: originals, motion and edited versions, not the previews
    let size: Int64
    /// When the first ones go for good: Photos keeps deleted items 30 days
    let firstPurge: Date?

    static let photosDatabase = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Pictures/Photos Library.photoslibrary/database/Photos.sqlite")

    static func read(_ database: URL = photosDatabase) -> Result<RecentlyDeleted, Failure> {
        // Without Full Disk Access macOS refuses even to open the file
        let descriptor = open(database.path, O_RDONLY)
        guard descriptor >= 0 else { return .failure(errno == ENOENT ? .unreadable : .noAccess) }
        close(descriptor)

        var connection: OpaquePointer?
        guard sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(connection)
            return .failure(.unreadable)
        }
        defer { sqlite3_close(connection) }
        // Photos writes to it all the time: wait a little rather than fail
        sqlite3_busy_timeout(connection, 2000)

        var count = 0
        var firstPurge: Date?
        var size: Int64 = 0
        let found =
            firstRow(connection, "SELECT COUNT(*), MIN(ZTRASHEDDATE) FROM ZASSET WHERE ZTRASHEDSTATE = 1") { row in
                count = Int(sqlite3_column_int64(row, 0))
                if sqlite3_column_type(row, 1) != SQLITE_NULL {
                    let deleted = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(row, 1))
                    firstPurge = deleted.addingTimeInterval(30 * 24 * 3600)
                }
            }
            // Each file is a resource: recipe 0 is an original (photo, video, Live Photo motion), and these three
            // recipes are the edited versions Photos renders; the other recipes are previews it can make again
            && firstRow(
                connection,
                """
                SELECT SUM(r.ZDATALENGTH) FROM ZINTERNALRESOURCE r JOIN ZASSET a ON r.ZASSET = a.Z_PK
                WHERE a.ZTRASHEDSTATE = 1 AND r.ZRESOURCETYPE IN (0, 1, 3)
                    AND (r.ZRECIPEID = 0 OR r.ZRECIPEID IN (65938, 131072, 131272))
                """
            ) { row in size = sqlite3_column_int64(row, 0) }
        return found ? .success(RecentlyDeleted(count: count, size: size, firstPurge: firstPurge)) : .failure(.unreadable)
    }

    private static func firstRow(_ connection: OpaquePointer?, _ query: String, _ read: (OpaquePointer?) -> Void) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, query, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return false }
        read(statement)
        return true
    }
}
