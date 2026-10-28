import Photos

/// Reading the library: every item with its files, the exact copies, and the counts the sidebar shows.
enum LibraryScan {
    /// `heicRefused`: the photos a HEIC conversion refused before
    nonisolated static func fetch(
        cached: [String: CachedResources], heicRefused: Set<String>, progress: @escaping (Int, Int) -> Void
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
            items.append(Item(asset: asset, resources: resources, heicRefused: heicRefused.contains(id)))
            if index % 250 == 0 { progress(index, assets.count) }
        }
        return (items, nextResources)
    }

    /// Copies of the same item, newest first. The copy to keep is a favorite, then an edited one, then the one
    /// in more albums (the one someone organised), then the biggest.
    nonisolated static func duplicateGroups(_ items: [Item]) -> [ItemGroup] {
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

    static func tallies(_ items: [Item], in context: ListContext) -> [Destination: Library.Tally] {
        var tallies: [Destination: Library.Tally] = [:]
        for item in items {
            for destination in Destination.allCases where destination.includes(item, in: context) {
                tallies[destination, default: Library.Tally()].count += 1
                tallies[destination, default: Library.Tally()].size += item.size
                tallies[destination, default: Library.Tally()].saving += destination.replacement?.saving(item) ?? 0
            }
        }
        return tallies
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
