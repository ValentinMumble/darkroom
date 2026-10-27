import Observation
import os
import Photos

private let log = Logger(subsystem: "com.valentinmumble.darkroom", category: "library")

/// The Photos library as the app shows it, and every change the app makes to it.
@MainActor
@Observable
final class Library {
    enum State: Equatable {
        case starting
        case denied
        case loading(done: Int, total: Int)
        case ready
    }

    struct Tally {
        var count = 0
        var size: Int64 = 0
        /// What replacing every item by its current version alone would free
        var saving: Int64 = 0
    }

    private(set) var state: State = .starting
    private(set) var items: [Item] = []
    private(set) var itemsById: [String: Item] = [:]
    private(set) var duplicateGroups: [ItemGroup] = []
    private(set) var tallies: [Destination: Tally] = [:]
    private(set) var storage: ICloudStorage?
    private(set) var recentlyDeleted: Result<RecentlyDeleted, RecentlyDeleted.Failure>?
    private(set) var similarGroups: [ItemGroup]?
    private(set) var similarProgress = 0.0
    private(set) var shrinkRecords: [String: ShrinkRecord] = ShrinkRecords.load()
    private(set) var shrinkStatus = ShrinkStatus()
    private(set) var savings: [Saving] = Savings.load()
    var error: String?

    @ObservationIgnored private var resources: [String: CachedResources] = [:]
    @ObservationIgnored private var fingerprints: [String: Similar.Fingerprint] = [:]
    @ObservationIgnored private var observer: ChangeObserver?
    @ObservationIgnored private var pendingReload: Task<Void, Never>?

    func start() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            state = .denied
            return
        }
        // Changes made in Photos (or by this app) show up here a moment later
        observer = ChangeObserver { [weak self] in
            Task { @MainActor in self?.scheduleReload() }
        }
        await reload()
    }

    func scheduleReload() {
        pendingReload?.cancel()
        pendingReload = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await reload()
        }
    }

    func reload() async {
        let started = Date.now
        let cached = resources
        let firstLoad = items.isEmpty
        let (loaded, nextResources) = await Task.detached(priority: .userInitiated) {
            Library.fetch(cached: cached) { done, total in
                guard firstLoad else { return }
                Task { @MainActor in self.state = .loading(done: done, total: total) }
            }
        }.value
        resources = nextResources
        items = loaded
        itemsById = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        shrinkStatus = ShrinkStatus(records: shrinkRecords)
        tallies = Self.tallies(loaded, shrink: shrinkStatus)
        state = .ready
        duplicateGroups = await Task.detached { Library.duplicateGroups(loaded) }.value
        let total = loaded.reduce(0) { $0 + $1.size }
        log.notice(
            "Loaded \(loaded.count) items, \(Format.bytes(total)), \(self.duplicateGroups.count) duplicate groups, in \(Date.now.timeIntervalSince(started), format: .fixed(precision: 1))s"
        )
        if similarGroups != nil { await computeSimilar() }
        await refreshStorage()
        log.notice(
            "iCloud: \(self.storage?.apps.count ?? 0) apps, plan \(self.storage?.total ?? 0), free \(self.storage?.free ?? 0)")
    }

    nonisolated private static func fetch(
        cached: [String: CachedResources], progress: @escaping (Int, Int) -> Void
    ) -> ([Item], [String: CachedResources]) {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: options)
        var items: [Item] = []
        var nextResources: [String: CachedResources] = [:]
        items.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, index, _ in
            let id = asset.localIdentifier
            let resources: Resources
            if let entry = cached[id], entry.modified == asset.modificationDate {
                resources = entry.resources
            } else {
                resources = Resources(asset: asset)
            }
            nextResources[id] = CachedResources(modified: asset.modificationDate, resources: resources)
            items.append(Item(asset: asset, resources: resources))
            if index % 250 == 0 { progress(index, assets.count) }
        }
        return (items, nextResources)
    }

    /// Copies of the same item, newest first. The copy to keep is a favorite, then an edited one, then the one
    /// in more albums (the one someone organised), then the biggest.
    nonisolated private static func duplicateGroups(_ items: [Item]) -> [ItemGroup] {
        let sets = Dictionary(grouping: items.filter { $0.duplicateKey != nil }, by: { $0.duplicateKey! })
            .values.filter { $0.count > 1 }
            .sorted { $0[0].date > $1[0].date }
        return sets.map { copies in
            let albums = Dictionary(
                uniqueKeysWithValues: copies.map {
                    ($0.id, PHAssetCollection.fetchAssetCollectionsContaining($0.asset, with: .album, options: nil).count)
                })
            let keep = copies.max { first, second in
                (first.favorite ? 1 : 0, first.edited ? 1 : 0, albums[first.id] ?? 0, first.size)
                    < (second.favorite ? 1 : 0, second.edited ? 1 : 0, albums[second.id] ?? 0, second.size)
            }!
            return ItemGroup(id: copies[0].id, itemIds: copies.map(\.id), pick: keep.id)
        }
    }

    private static func tallies(_ items: [Item], shrink: ShrinkStatus) -> [Destination: Tally] {
        var tallies: [Destination: Tally] = [:]
        for item in items {
            for destination in Destination.allCases where destination.includes(item, shrink: shrink) {
                tallies[destination, default: Tally()].count += 1
                tallies[destination, default: Tally()].size += item.size
                tallies[destination, default: Tally()].saving += destination.replacement?.saving(item) ?? 0
            }
        }
        return tallies
    }

    // MARK: Similar shots

    func findSimilar() async {
        guard similarGroups == nil else { return }
        await computeSimilar()
    }

    /// Replaces the groups only once the new ones are ready, so the view keeps its place. Fingerprints are
    /// cached, so after the first time only new photos cost anything.
    private func computeSimilar() async {
        let started = Date.now
        let photos = items.filter { $0.kind == .photo && !$0.screenshot }
        let known = fingerprints
        let (groups, computed) = await Task.detached(priority: .userInitiated) {
            Similar.groups(photos, known: known) { fraction in
                Task { @MainActor in self.similarProgress = fraction }
            }
        }.value
        fingerprints = computed
        similarGroups = groups
        log.notice(
            "Similar: \(groups.count) groups of \(groups.reduce(0) { $0 + $1.itemIds.count }) photos in \(Date.now.timeIntervalSince(started), format: .fixed(precision: 1))s"
        )
    }

    // MARK: Changes

    /// Deletes for real: macOS asks for confirmation, and the items go to Recently Deleted for 30 days.
    func delete(_ targets: [Item]) async {
        let assets = targets.map(\.asset) as NSArray
        guard await change({ PHAssetChangeRequest.deleteAssets(assets) }) else { return }
        // A shrunk original frees only what its copy does not take back
        let shrunk = targets.filter { shrinkRecords[$0.id]?.copy != nil }
        let others = targets.filter { shrinkRecords[$0.id]?.copy == nil }
        addSaving(.shrunk, shrunk.count, shrunk.reduce(0) { $0 + max(0, $1.size - (shrinkRecords[$1.id]?.after ?? 0)) })
        addSaving(.deleted, others.count, others.reduce(0) { $0 + $1.size })
    }

    func setFavorite(_ targets: [Item], _ favorite: Bool) async {
        await change {
            for item in targets { PHAssetChangeRequest(for: item.asset).isFavorite = favorite }
        }
    }

    func setDates(_ changes: [(Item, Date)]) async {
        await change {
            for (item, date) in changes { PHAssetChangeRequest(for: item.asset).creationDate = date }
        }
    }

    /// Whether the change went through
    @discardableResult
    private func change(_ block: @escaping () -> Void) async -> Bool {
        do {
            try await PHPhotoLibrary.shared().performChanges(block)
        } catch let failure as NSError where failure.domain == PHPhotosErrorDomain
            && failure.code == PHPhotosError.userCancelled.rawValue
        {
            return false
        } catch {
            self.error = error.localizedDescription
            return false
        }
        await reload()
        return true
    }

    private func addSaving(_ kind: Saving.Kind, _ count: Int, _ bytes: Int64) {
        guard count > 0 else { return }
        savings.append(Saving(date: .now, kind: kind, count: count, bytes: bytes))
        Savings.save(savings)
    }

    struct ReplaceOutcome {
        var replaced = 0
        var freed: Int64 = 0
        var failed: [String] = []
        var cancelled = false
    }

    /// One confirmation per this many items: big enough to stay rare, small enough to keep each change light
    private static let replaceBatch = 200

    /// Replaces items by their current version alone (see Replacement). `progress` gets a message and how
    /// many items are done.
    func replace(_ targets: [Item], kind: Replacement, progress: @escaping (String, Int) -> Void) async -> ReplaceOutcome {
        var outcome = ReplaceOutcome()
        let folder = FileManager.default.temporaryDirectory.appending(path: "darkroom-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        var done = 0
        for start in stride(from: 0, to: targets.count, by: Self.replaceBatch) {
            var entries: [Replacer.Entry] = []
            for item in targets[start..<min(start + Self.replaceBatch, targets.count)] {
                progress("Getting the current version of each item from Photos…", done)
                do {
                    let motion = kind.keepsMotion(item)
                    entries.append(try await Task.detached { try await Replacer.exportCurrent(item, to: folder, motion: motion) }.value)
                } catch {
                    log.error("Could not export \(item.filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    outcome.failed.append("\(item.filename) (\(error.localizedDescription))")
                }
                done += 1
            }
            guard !entries.isEmpty else { continue }
            progress("Waiting for you to confirm the deletion…", done)
            do {
                try await Task.detached { [entries] in try await Replacer.replace(entries) }.value
                let freed = entries.reduce(0) { $0 + kind.saving($1.item) }
                outcome.replaced += entries.count
                outcome.freed += freed
                addSaving(kind == .removeMotion ? .removedMotion : .keptEdit, entries.count, freed)
            } catch let failure as NSError where failure.domain == PHPhotosErrorDomain
                && failure.code == PHPhotosError.userCancelled.rawValue
            {
                outcome.cancelled = true
                break
            } catch {
                self.error = error.localizedDescription
                break
            }
            for entry in entries { try? FileManager.default.removeItem(at: entry.file.deletingLastPathComponent()) }
        }
        await reload()
        return outcome
    }

    /// iCloud storage changes outside the library too (a deleted backup), so it is read again on its own
    func refreshStorage() async {
        storage = await Task.detached { ICloudStorage.read() }.value
        // Read with it, so emptying Recently Deleted in Photos shows when coming back
        recentlyDeleted = await Task.detached { RecentlyDeleted.read() }.value
    }

    // MARK: Shrinking

    func saveShrinkRecord(_ record: ShrinkRecord) {
        shrinkRecords[record.original] = record
        ShrinkRecords.save(shrinkRecords)
        shrinkStatus = ShrinkStatus(records: shrinkRecords)
        tallies = Self.tallies(items, shrink: shrinkStatus)
    }

    /// Why a video cannot be shrunk, or nil
    func shrinkSkip(_ item: Item) -> String? {
        if item.kind != .video { return "not a video" }
        if item.slowMotion { return "slow motion: the copy would lose it" }
        if shrinkStatus.shrunk.contains(item.id) { return "already shrunk" }
        if shrinkStatus.copies[item.id] != nil { return "is a shrunk copy" }
        return nil
    }

    /// What shrinking did to a video, whether it is the original or the copy
    func shrinkRecord(_ item: Item) -> ShrinkRecord? {
        shrinkRecords[item.id] ?? shrinkStatus.copies[item.id].flatMap { shrinkRecords[$0] }
    }
}

struct CachedResources {
    let modified: Date?
    let resources: Resources
}

/// Tells the library when Photos changes, whoever made the change.
final class ChangeObserver: NSObject, PHPhotoLibraryChangeObserver {
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange()
    }
}
