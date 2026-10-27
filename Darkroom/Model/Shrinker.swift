import Foundation
import Observation
import os
import Photos

private let log = Logger(subsystem: "com.valentinmumble.darkroom", category: "shrink")

enum ShrinkPreset: String, CaseIterable, Identifiable, Codable {
    case high, small

    var id: String { rawValue }

    // Measured on the library's videos: CRF 26 scores VMAF 95-96 on iPhone footage, CRF 28 scores 90-92
    var crf: Int { self == .high ? 26 : 28 }
    var defaultMinQuality: Double { self == .high ? 93 : 88 }

    /// The score a copy needs to be kept: the default, or what was last set in the Shrink window
    var minQuality: Double {
        get { UserDefaults.standard.object(forKey: minQualityKey) as? Double ?? defaultMinQuality }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: minQualityKey) }
    }

    private var minQualityKey: String { "MinQuality.\(rawValue)" }

    var label: String { self == .high ? "High quality" : "Smaller files" }
    var detail: String { self == .high ? "CRF 26, hard to tell apart" : "CRF 28, slightly softer" }
}

/// What happened to one video. Saved, so the app remembers across launches which videos were shrunk.
struct ShrinkRecord: Codable, Identifiable {
    /// Local identifier of the original
    let original: String
    let name: String
    /// Local identifier of the copy in Photos, when one was kept
    let copy: String?
    /// Why the original was kept as it was
    let kept: String?
    let before: Int64
    let after: Int64
    let vmaf: Double?
    /// The score the copy needed, as set when it was made: missing from older records
    let minQuality: Double?
    /// No copy went into Photos, but one waits aside to be compared: missing from older records
    var keptAside: Bool? = nil
    let preset: ShrinkPreset
    let from: String
    let to: String
    let date: Date

    var id: String { original }

    /// "27 MB → 16 MB (−40%)"
    var sizes: String {
        let percent = Int(((Double(after) / Double(before)) - 1) * 100)
        let change = percent > 0 ? "+\(percent)%" : "−\(-percent)%"
        return "\(Format.bytes(before)) → \(Format.bytes(after)) (\(change))"
    }

    /// "27 MB → 16 MB (−40%), quality 95.3"
    var summary: String {
        sizes + (vmaf.map { ", quality \($0)" } ?? "")
    }

    var requiredQuality: Double { minQuality ?? preset.defaultMinQuality }

    /// Refused for its quality score or its frame count, not its size, so the copy can be saved anyway (older
    /// records kept aside only copies refused for their score)
    var reviewable: Bool { copy == nil && (keptAside ?? (vmaf != nil)) }
}

/// The ids the sidebar and the skip rules need, taken from the saved records
struct ShrinkStatus {
    var shrunk: Set<String> = []
    /// Each copy's original
    var copies: [String: String] = [:]
    var kept: Set<String> = []

    init(records: [String: ShrinkRecord] = [:]) {
        for record in records.values {
            if let copy = record.copy {
                shrunk.insert(record.original)
                copies[copy] = record.original
            } else {
                kept.insert(record.original)
            }
        }
    }
}

enum ShrinkRecords {
    private static let file = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Darkroom/shrink.json")

    static func load() -> [String: ShrinkRecord] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: ShrinkRecord].self, from: data)) ?? [:]
    }

    /// Where a copy refused for its quality waits until it is saved anyway or discarded: one folder per
    /// video, so the file keeps the video's name
    static func preview(original: String, name: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Caches/Darkroom/Previews")
            .appending(path: original.replacingOccurrences(of: "/", with: "_"))
            .appending(path: (name as NSString).deletingPathExtension + ".mov")
    }

    static func preview(_ record: ShrinkRecord) -> URL? {
        let file = preview(original: record.original, name: record.name)
        return record.reviewable && FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    static func discardPreview(_ record: ShrinkRecord) {
        try? FileManager.default.removeItem(at: preview(original: record.original, name: record.name).deletingLastPathComponent())
    }

    static func save(_ records: [String: ShrinkRecord]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(records).write(to: file)
    }
}

/// Shrinks videos one at a time. Nothing is deleted here: the copies go into Photos next to the originals,
/// and the Shrinking view deletes the originals when asked.
@MainActor
@Observable
final class Shrinker {
    enum Phase: String {
        case queued, downloading, encoding, checking, importing, done, kept, failed, cancelled

        var active: Bool { [.queued, .downloading, .encoding, .checking, .importing].contains(self) }

        var label: String {
            switch self {
            case .queued: "Waiting"
            case .downloading: "Getting the original from Photos"
            case .encoding: "Encoding"
            case .checking: "Checking quality"
            case .importing: "Saving the copy to Photos"
            case .done: "Copy saved to Photos"
            case .kept: "Not shrunk"
            case .failed: "Failed"
            case .cancelled: "Cancelled"
            }
        }
    }

    struct Job: Identifiable {
        let id = UUID()
        let item: Item
        let preset: ShrinkPreset
        /// Read when the job is queued, so changing the setting later leaves it alone
        let minQuality: Double
        var phase = Phase.queued
        var progress = 0.0
        /// How much of the video has come from Photos: it can start before the job's turn, and is 1 once done
        var downloaded: Double?
        var record: ShrinkRecord?
        var error: String?
    }

    /// A job's video being fetched from Photos into a folder of its own, possibly ahead of its turn
    private struct Download {
        let jobId: UUID
        let folder: URL
        let file: Task<URL, Error>

        func discard() {
            file.cancel()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Keep a copy only when it is at least this much smaller
    nonisolated static let minSaving = 0.2

    private(set) var jobs: [Job] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    private let library: Library

    init(library: Library) {
        self.library = library
    }

    var running: Int { jobs.filter(\.phase.active).count }

    func enqueue(_ items: [Item], preset: ShrinkPreset) {
        let busy = Set(jobs.filter(\.phase.active).map(\.item.id))
        jobs += items.filter { !busy.contains($0.id) && library.shrinkSkip($0) == nil }.map { Job(item: $0, preset: preset, minQuality: preset.minQuality) }
        if worker == nil { worker = Task { await work() } }
    }

    func cancelWaiting() {
        for index in jobs.indices where jobs[index].phase == .queued { jobs[index].phase = .cancelled }
    }

    func clearFinished() {
        jobs.removeAll { !$0.phase.active }
    }

    private func work() async {
        var ahead: Download?
        while let job = jobs.first(where: { $0.phase == .queued }) {
            // Deleted while it waited: nothing left to shrink
            guard library.itemsById[job.item.id] != nil else {
                update(job.id) { job in
                    job.phase = .cancelled
                    job.error = "The original was deleted"
                }
                continue
            }
            let download: Download
            if let ahead, ahead.jobId == job.id {
                download = ahead
            } else {
                ahead?.discard()
                download = startDownload(job)
            }
            // The next video downloads while this one is shrunk, so it is ready when its turn comes
            ahead = jobs.first { $0.phase == .queued && $0.id != job.id }.map(startDownload)
            await run(job, download)
        }
        ahead?.discard()
        worker = nil
    }

    private func startDownload(_ job: Job) -> Download {
        let id = job.id
        let item = job.item
        let folder = FileManager.default.temporaryDirectory.appending(path: "darkroom-\(UUID().uuidString)")
        let file = Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // The video as Photos shows it, so an edited one (rotated, trimmed) keeps its edit in the copy
            let source = try await Replacer.exportCurrent(item, to: folder) { fraction in
                // Reports can arrive out of order: never step back
                Task { @MainActor in self.update(id) { $0.downloaded = max($0.downloaded ?? 0, fraction) } }
            }.file
            await MainActor.run { self.update(id) { $0.downloaded = 1 } }
            return source
        }
        return Download(jobId: id, folder: folder, file: file)
    }

    private func run(_ job: Job, _ download: Download) async {
        let id = job.id
        let folder = download.folder
        defer { try? FileManager.default.removeItem(at: folder) }
        update(id) { $0.phase = .downloading }
        do {
            let source = try await download.file.value
            let record = try await Task.detached(priority: .utility) {
                try await Shrinker.shrink(
                    job.item, source: source, preset: job.preset, minQuality: job.minQuality, in: folder
                ) { phase, progress in
                    Task { @MainActor in
                        // A late progress report must not undo the final state
                        self.update(id) { job in
                            guard job.phase.active else { return }
                            job.phase = phase
                            job.progress = progress
                        }
                    }
                }
            }.value
            library.saveShrinkRecord(record)
            log.notice("Shrunk \(record.name, privacy: .public): \(record.summary, privacy: .public), \(record.kept ?? "copy saved", privacy: .public)")
            update(id) { job in
                job.record = record
                job.phase = record.copy == nil ? .kept : .done
                job.progress = 1
            }
        } catch {
            log.error("Shrink failed for \(job.item.filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
            update(id) { job in
                job.phase = .failed
                job.error = error.localizedDescription
            }
        }
    }

    /// Saves a copy refused for its quality score after all, from the file kept aside for comparing
    func saveAnyway(_ record: ShrinkRecord) async throws {
        guard let file = ShrinkRecords.preview(record), let original = library.itemsById[record.original] else {
            throw FFmpeg.Failure(message: "the copy or the original is no longer there")
        }
        let copyId = try await Shrinker.importCopy(file, like: original.asset)
        library.saveShrinkRecord(
            ShrinkRecord(
                original: record.original, name: record.name, copy: copyId, kept: nil, before: record.before,
                after: record.after, vmaf: record.vmaf, minQuality: record.minQuality, preset: record.preset, from: record.from, to: record.to,
                date: .now))
        ShrinkRecords.discardPreview(record)
        log.notice("Saved \(record.name, privacy: .public) anyway: \(record.summary, privacy: .public)")
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        if let index = jobs.firstIndex(where: { $0.id == id }) { change(&jobs[index]) }
    }

    // MARK: Pipeline

    nonisolated private static func shrink(
        _ item: Item, source: URL, preset: ShrinkPreset, minQuality: Double, in folder: URL,
        report: @escaping (Phase, Double) -> Void
    ) async throws -> ShrinkRecord {
        let original = try FFmpeg.probe(source)

        report(.encoding, 0)
        let outputFolder = folder.appending(path: "out")
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        let output = outputFolder.appending(path: source.deletingPathExtension().lastPathComponent + ".mov")
        try FFmpeg.encode(source, to: output, crf: preset.crf, duration: original.duration) { report(.encoding, $0) }
        let copy = try FFmpeg.probe(output)

        let before = try fileSize(source)
        let after = try fileSize(output)
        func record(copy copyId: String? = nil, kept: String? = nil, vmaf: Double? = nil, aside: Bool = false) -> ShrinkRecord {
            ShrinkRecord(
                original: item.id, name: item.filename, copy: copyId, kept: kept, before: before, after: after,
                vmaf: vmaf, minQuality: minQuality, keptAside: aside, preset: preset, from: original.summary,
                to: copy.summary, date: .now)
        }
        // Refused, but worth a look: the copy waits until it is saved anyway or discarded
        func keepAside() throws {
            let preview = ShrinkRecords.preview(original: item.id, name: item.filename)
            try? FileManager.default.removeItem(at: preview.deletingLastPathComponent())
            try FileManager.default.createDirectory(at: preview.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: output, to: preview)
        }
        let saving = 1 - Double(after) / Double(before)
        if after >= before {
            return record(kept: "the copy is \(Int((Double(after) / Double(before) - 1) * 100))% bigger")
        }
        if saving < minSaving {
            return record(kept: "the copy saves only \(Int(saving * 100))%")
        }
        // One frame short is allowed: x265 sometimes drops the last one. Beyond that the quality check cannot
        // pair the frames, so the copy waits for a look instead
        if abs(copy.frames - original.frames) > 1 {
            try keepAside()
            return record(
                kept: "it has \(copy.frames) frames instead of \(original.frames), so its quality could not be measured", aside: true)
        }

        report(.checking, 1)
        let score = try FFmpeg.vmaf(output, against: source)
        if score < minQuality {
            try keepAside()
            return record(kept: "the copy would look softer (quality \(score), below \(Int(minQuality)))", vmaf: score, aside: true)
        }

        report(.importing, 1)
        // Deleted while it was being shrunk: a copy would be an orphan
        guard PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil).count > 0 else {
            throw FFmpeg.Failure(message: "the original was deleted meanwhile, so no copy was saved")
        }
        let copyId = try await importCopy(output, like: item.asset)
        return record(copy: copyId, vmaf: score)
    }

    /// Saves the copy with the original's date, place and favorite, in the same albums
    nonisolated private static func importCopy(_ file: URL, like original: PHAsset) async throws -> String {
        final class Placeholder: @unchecked Sendable { var id: String? }
        let placeholder = Placeholder()
        let albums = PHAssetCollection.fetchAssetCollectionsContaining(original, with: .album, options: nil)
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = file.lastPathComponent
            request.addResource(with: .video, fileURL: file, options: options)
            request.creationDate = original.creationDate
            request.location = original.location
            request.isFavorite = original.isFavorite
            guard let created = request.placeholderForCreatedAsset else { return }
            placeholder.id = created.localIdentifier
            albums.enumerateObjects { album, _, _ in
                if album.canPerform(.addContent) {
                    PHAssetCollectionChangeRequest(for: album)?.addAssets([created] as NSArray)
                }
            }
        }
        guard let id = placeholder.id else { throw FFmpeg.Failure(message: "Photos did not save the copy") }
        return id
    }

    nonisolated private static func fileSize(_ file: URL) throws -> Int64 {
        (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
    }
}
