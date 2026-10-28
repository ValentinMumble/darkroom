import AVFoundation
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

/// A lighter version of an item that replaces it: a Live Photo's still (Remove Motion), or an edited item's
/// edited version alone (Keep Edited Version). Either way the version kept is the one Photos shows now, so
/// an edit stays applied. Remove Motion drops every motion clip; Keep Edited Version keeps a Live Photo
/// live, with its edited motion, and drops what lies under the edit.
enum Replacement: String, Identifiable {
    case removeMotion, keepEdit

    var id: String { rawValue }

    var title: String { self == .removeMotion ? "Remove Motion" : "Keep Edited Version" }

    /// Keep Edited Version needs a second file to free: a slow-motion video's edit, for one, is only a setting
    /// Photos applies when playing it
    func applies(to item: Item) -> Bool {
        self == .removeMotion ? item.live || item.hiddenMotion : item.edited && item.editedSize > 0
    }

    /// Whether the new item is a Live Photo too
    func keepsMotion(_ item: Item) -> Bool {
        self == .keepEdit && item.live
    }

    /// Bytes freed: everything stored for the item, minus the files kept
    func saving(_ item: Item) -> Int64 {
        let still = item.edited && item.editedSize > 0 ? item.editedSize : item.originalSize
        let motion = keepsMotion(item) ? item.currentMotionSize : 0
        return max(0, item.size - still - motion)
    }

    /// Bytes freed by replacing those of `items` this applies to
    func saving(of items: [Item]) -> Int64 {
        items.filter(applies).reduce(0) { $0 + saving($1) }
    }
}

enum Replacer {
    struct Entry {
        let item: Item
        let file: URL
        let type: PHAssetResourceType
        /// A Live Photo's motion, saved with the still
        let motion: URL?
    }

    /// Writes the version Photos shows now (with its edit) to a file of its own, and with `motion` a Live
    /// Photo's motion as well. `progress` hears how much of a video has come from iCloud.
    nonisolated static func exportCurrent(
        _ item: Item, to folder: URL, motion: Bool = false, progress: ((Double) -> Void)? = nil
    ) async throws -> Entry {
        let itemFolder = folder.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: itemFolder, withIntermediateDirectories: true)
        let stem = (item.filename as NSString).deletingPathExtension
        let resources = PHAssetResource.assetResources(for: item.asset)
        func current(_ edited: PHAssetResourceType, else original: PHAssetResourceType) -> PHAssetResource? {
            resources.first { $0.type == edited } ?? resources.first { $0.type == original }
        }
        if item.kind == .video {
            guard let resource = current(.fullSizeVideo, else: .video) else { throw FFmpeg.Failure(message: "no video file") }
            let file = try await write(resource, stem: stem, to: itemFolder, progress: progress)
            return Entry(item: item, file: file, type: .video, motion: nil)
        }
        if motion {
            // Photos renders an edited Live Photo's still and motion with the same pairing id, so together
            // they make a Live Photo again
            func pair(_ still: PHAssetResource?, _ clip: PHAssetResource?, in folder: URL) async throws -> (URL, URL) {
                guard let still, let clip else { throw FFmpeg.Failure(message: "no Live Photo files") }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                return (try await write(still, stem: stem, to: folder), try await write(clip, stem: stem, to: folder))
            }
            let stillFile: URL
            let clipFile: URL
            do {
                (stillFile, clipFile) = try await pair(
                    current(.fullSizePhoto, else: .photo), current(.fullSizePairedVideo, else: .pairedVideo), in: itemFolder)
            } catch {
                // Some items kept in iCloud fail here with Photos' internal error -1: have Photos render the Live
                // Photo instead, as apps share one
                let rendered = PHAssetResource.assetResources(for: try await currentLivePhoto(item.asset))
                (stillFile, clipFile) = try await pair(
                    rendered.first { $0.type == .photo }, rendered.first { $0.type == .pairedVideo },
                    in: itemFolder.appending(path: "rendered"))
            }
            // A Loop or Bounce effect renders a plain video without the id: Photos would refuse the pair, and
            // with it the whole batch
            let stillID = stillPairingID(stillFile)
            let clipID = await motionPairingID(clipFile)
            guard let stillID, stillID == clipID else {
                throw FFmpeg.Failure(message: "its still and motion do not pair up (a Loop or Bounce effect?)")
            }
            return Entry(item: item, file: stillFile, type: .photo, motion: clipFile)
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
        try makeNew(file)
        return Entry(item: item, file: file, type: .photo, motion: nil)
    }

    /// Rewrites a still with one tag of its own, without re-encoding it. An unedited photo comes from Photos as its
    /// original file, byte for byte, and iCloud takes such a copy for the original: it attached the original's
    /// motion clip back to it, so Remove Motion freed nothing.
    nonisolated private static func makeNew(_ file: URL) throws {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil), let type = CGImageSourceGetType(source),
            let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
            let tagged = CGImageMetadataCreateMutableCopy(metadata)
        else { throw FFmpeg.Failure(message: "could not read the still to save it as a new file") }
        CGImageMetadataSetValueWithPath(tagged, nil, "xmp:MetadataDate" as CFString, Date.now.ISO8601Format() as CFString)
        let rewritten = file.deletingLastPathComponent().appending(path: "new-" + file.lastPathComponent)
        let options = [kCGImageDestinationMetadata: tagged, kCGImageDestinationMergeMetadata: false] as CFDictionary
        guard let destination = CGImageDestinationCreateWithURL(rewritten as CFURL, type, 1, nil),
            CGImageDestinationCopyImageSource(destination, source, options, nil)
        else { throw FFmpeg.Failure(message: "could not save the still as a new file") }
        _ = try FileManager.default.replaceItemAt(file, withItemAt: rewritten)
    }

    /// The Live Photo as Photos shows it, downloaded and rendered when needed
    nonisolated private static func currentLivePhoto(_ asset: PHAsset) async throws -> PHLivePhoto {
        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        return try await withCheckedThrowingContinuation { continuation in
            let options = PHLivePhotoRequestOptions()
            options.version = .current
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestLivePhoto(
                for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .default, options: options
            ) { livePhoto, info in
                // Only the full version, and only once
                guard (info?[PHImageResultIsDegradedKey] as? Bool) != true, !once.done else { return }
                once.done = true
                if let livePhoto {
                    continuation.resume(returning: livePhoto)
                } else {
                    continuation.resume(throwing: (info?[PHImageErrorKey] as? Error) ?? FFmpeg.Failure(message: "Photos gave no Live Photo"))
                }
            }
        }
    }

    /// The id a Live Photo's still and motion share: in the still, Apple's maker note, key 17
    nonisolated private static func stillPairingID(_ file: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
            let maker = properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any]
        else { return nil }
        return maker["17"] as? String
    }

    /// In the motion, the QuickTime content identifier
    nonisolated private static func motionPairingID(_ file: URL) async -> String? {
        let metadata = (try? await AVURLAsset(url: file).load(.metadata)) ?? []
        let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .quickTimeMetadataContentIdentifier).first
        return try? await item?.load(.stringValue)
    }

    /// Writes one of the item's files, named after the item (an edit's file is called FullSizeRender)
    nonisolated private static func write(
        _ resource: PHAssetResource, stem: String, to folder: URL, progress: ((Double) -> Void)? = nil
    ) async throws -> URL {
        let file = folder.appending(path: stem + "." + (resource.originalFilename as NSString).pathExtension)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        // Photos calls it only while downloading from iCloud, not for a file already on this Mac
        options.progressHandler = progress
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: file, options: options)
        return file
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
                if let motion = entry.motion {
                    let motionOptions = PHAssetResourceCreationOptions()
                    motionOptions.originalFilename = motion.lastPathComponent
                    request.addResource(with: .pairedVideo, fileURL: motion, options: motionOptions)
                }
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
