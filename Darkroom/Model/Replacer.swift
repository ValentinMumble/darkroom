import Foundation
import Photos
import UniformTypeIdentifiers

/// A lighter version of an item that replaces it: a Live Photo's still (Remove Motion), or an edited item's
/// edited version alone (Keep Edited Version). Either way the version kept is the one Photos shows now, so
/// an edit stays applied, and everything else stored for the item (motion clips, the original under an
/// edit) goes.
enum Replacement: String, Identifiable {
    case removeMotion, keepEdit

    var id: String { rawValue }

    var title: String { self == .removeMotion ? "Remove Motion" : "Keep Edited Version" }

    func applies(to item: Item) -> Bool {
        self == .removeMotion ? item.live : item.edited
    }

    /// Bytes freed: everything stored for the item, minus the one file kept
    static func saving(_ item: Item) -> Int64 {
        let kept = item.edited && item.editedSize > 0 ? item.editedSize : item.originalSize
        return max(0, item.size - kept)
    }
}

enum Replacer {
    struct Entry {
        let item: Item
        let file: URL
        let type: PHAssetResourceType
    }

    /// Writes the version Photos shows now (with its edit) to a file of its own
    nonisolated static func exportCurrent(_ item: Item, to folder: URL) async throws -> Entry {
        let itemFolder = folder.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: itemFolder, withIntermediateDirectories: true)
        let stem = (item.filename as NSString).deletingPathExtension
        if item.kind == .video {
            let resources = PHAssetResource.assetResources(for: item.asset)
            guard let resource = resources.first(where: { $0.type == .fullSizeVideo }) ?? resources.first(where: { $0.type == .video })
            else { throw FFmpeg.Failure(message: "no video file") }
            let file = itemFolder.appending(path: stem + "." + ((resource.originalFilename as NSString).pathExtension))
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            try await PHAssetResourceManager.default().writeData(for: resource, toFile: file, options: options)
            return Entry(item: item, file: file, type: .video)
        }
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        let (data, uti): (Data, String?) = try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: item.asset, options: options) { data, uti, _, info in
                if let data {
                    continuation.resume(returning: (data, uti))
                } else {
                    let error = info?[PHImageErrorKey] as? Error
                    continuation.resume(throwing: error ?? FFmpeg.Failure(message: "Photos gave no image"))
                }
            }
        }
        let fileExtension = uti.flatMap { UTType($0)?.preferredFilenameExtension } ?? "heic"
        let file = itemFolder.appending(path: stem + "." + fileExtension)
        try data.write(to: file)
        return Entry(item: item, file: file, type: .photo)
    }

    /// Creates the new items and deletes the old ones in one change: macOS asks once for the batch, and if
    /// the deletion is refused nothing is created either, so no duplicates are left behind.
    nonisolated static func replace(_ entries: [Entry]) async throws {
        let albums = entries.map {
            PHAssetCollection.fetchAssetCollectionsContaining($0.item.asset, with: .album, options: nil)
        }
        try await PHPhotoLibrary.shared().performChanges {
            for (entry, itemAlbums) in zip(entries, albums) {
                let original = entry.item.asset
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = entry.file.lastPathComponent
                request.addResource(with: entry.type, fileURL: entry.file, options: options)
                request.creationDate = original.creationDate
                request.location = original.location
                request.isFavorite = original.isFavorite
                guard let created = request.placeholderForCreatedAsset else { continue }
                itemAlbums.enumerateObjects { album, _, _ in
                    if album.canPerform(.addContent) {
                        PHAssetCollectionChangeRequest(for: album)?.addAssets([created] as NSArray)
                    }
                }
            }
            PHAssetChangeRequest.deleteAssets(entries.map(\.item.asset) as NSArray)
        }
    }
}
