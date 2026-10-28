import Foundation
import SQLite3

/// iCloud storage by app, the plan size and the space left.
///
/// macOS has no API for this. Its iCloud notification agent caches the answers of Apple's quota service,
/// among them `getCloudStorageApps`: the storage used by each app, the numbers of System Settings. The plan
/// size follows from the share of the plan each app takes, and `brctl quota` gives the free space live.
struct ICloudStorage {
    struct App: Identifiable {
        let label: String
        let size: Int64
        var id: String { label }
    }

    let apps: [App]
    let total: Int64?
    let free: Int64?
    let fetchedAt: Date?

    var used: Int64 { apps.reduce(0) { $0 + $1.size } }

    private static let gib: Int64 = 1 << 30
    private static let plans: [Int64] = [5, 50, 200, 2048, 6144, 12288].map { $0 * gib }
    private static let cache = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Caches/com.apple.iCloudNotificationAgent")
    private static let query = """
        select response.time_stamp, data.isDataOnFS, data.receiver_data
        from cfurl_cache_response response join cfurl_cache_receiver_data data on data.entry_ID = response.entry_ID
        where response.request_key like '%/getCloudStorageApps%'
        order by response.time_stamp desc limit 1
        """

    private struct Answer: Decodable {
        struct Usage: Decodable {
            let appId: String
            let label: String
            let storageUsageInBytes: Int64
        }
        struct Thermometer: Decodable {
            struct Section: Decodable {
                let bundleId: String?
                let storagePercentage: Double?
            }
            let sections: [Section]
        }
        let apps: [Usage]
        let thermometer: Thermometer?
    }

    static func read() -> ICloudStorage {
        let free = freeSpace()
        guard let (stamp, body) = cachedAnswer(), let answer = try? JSONDecoder().decode(Answer.self, from: body) else {
            return ICloudStorage(apps: [], total: nil, free: free, fetchedAt: nil)
        }
        let apps = answer.apps.filter { $0.storageUsageInBytes > 0 }
            .sorted { $0.storageUsageInBytes > $1.storageUsageInBytes }
            .map { App(label: $0.label, size: $0.storageUsageInBytes) }
        let sizes = Dictionary(answer.apps.map { ($0.appId, $0.storageUsageInBytes) }, uniquingKeysWith: +)
        var total: Int64?
        for section in answer.thermometer?.sections ?? [] {
            guard let bundleId = section.bundleId, let size = sizes[bundleId], size > 0,
                let percentage = section.storagePercentage, percentage > 0
            else { continue }
            let estimate = Double(size) * 100 / percentage
            total = plans.min { abs(Double($0) - estimate) < abs(Double($1) - estimate) }
            break
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return ICloudStorage(apps: apps, total: total, free: free, fetchedAt: formatter.date(from: stamp))
    }

    /// The newest cached `getCloudStorageApps` answer and its time stamp (UTC)
    private static func cachedAnswer() -> (String, Data)? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(cache.appending(path: "Cache.db").path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let stampText = sqlite3_column_text(statement, 0),
            let blob = sqlite3_column_blob(statement, 2)
        else { return nil }
        let stamp = String(cString: stampText)
        let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 2)))
        // Bigger answers live in a file next to the database, named by the cell
        if sqlite3_column_int(statement, 1) != 0 {
            let name = String(decoding: data, as: UTF8.self)
            guard let body = try? Data(contentsOf: cache.appending(path: "fsCachedData/\(name)")) else { return nil }
            return (stamp, body)
        }
        return (stamp, data)
    }

    private static func freeSpace() -> Int64? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/brctl")
        process.arguments = ["quota"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return output.split(separator: " ").first.flatMap { Int64($0) }
    }
}
