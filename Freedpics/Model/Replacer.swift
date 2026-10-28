import AVFoundation
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

/// A lighter version of an item that replaces it: a Live Photo's still (Remove Motion), an edited item's
/// edited version alone (Keep Edited Version), or a JPEG photo saved as HEIC (Convert to HEIC). The version
/// kept is the one Photos shows now, so an edit stays applied. Remove Motion drops every motion clip; Keep
/// Edited Version keeps a Live Photo live, with its edited motion, and drops what lies under the edit.
enum Replacement: String, Identifiable {
    case removeMotion, keepEdit, convertToHEIC

    var id: String { rawValue }

    var title: String {
        switch self {
        case .removeMotion: "Remove Motion"
        case .keepEdit: "Keep Edited Version"
        case .convertToHEIC: "Convert to HEIC"
        }
    }

    func applies(to item: Item) -> Bool {
        switch self {
        case .removeMotion: item.live || item.hiddenMotion
        // It needs a second file to free: a slow-motion video's edit, for one, is only a setting Photos applies
        case .keepEdit: item.edited && item.editedSize > 0
        // Live, edited and hidden-motion photos have replacements of their own, which keep what matters in them.
        // A JPEG already compressed hard rarely gains (see Stills), and one refused before stays as it is.
        case .convertToHEIC:
            item.kind == .photo && item.isJPEG && !item.live && !item.edited && !item.hiddenMotion && !item.heicRefused
                && Stills.bitsPerPixel(size: item.originalSize, pixels: item.width * item.height) >= Stills.minBitsPerPixel
        }
    }

    /// Where the saved space is counted
    var savingKind: Saving.Kind {
        switch self {
        case .removeMotion: .removedMotion
        case .keepEdit: .keptEdit
        case .convertToHEIC: .convertedToHEIC
        }
    }

    /// The new item's files, written into `folder`
    nonisolated func export(_ item: Item, to folder: URL) async throws -> Replacer.Entry {
        switch self {
        case .removeMotion, .keepEdit: try await Replacer.exportCurrent(item, to: folder, motion: keepsMotion(item))
        case .convertToHEIC: try await Replacer.exportHEIC(item, to: folder)
        }
    }

    /// Whether the new item is a Live Photo too
    func keepsMotion(_ item: Item) -> Bool {
        self == .keepEdit && item.live
    }

    /// Bytes freed: everything stored for the item, minus the files kept. A HEIC's size is known only once
    /// converted, so before that it is the share measured on the library's JPEGs, refusals included.
    func saving(_ item: Item) -> Int64 {
        if self == .convertToHEIC {
            let bits = Stills.bitsPerPixel(size: item.originalSize, pixels: item.width * item.height)
            return Int64(Double(item.size) * Stills.expectedSaving(bitsPerPixel: bits))
        }
        return Self.saving(
            size: item.size, original: item.originalSize, edited: item.edited && item.editedSize > 0 ? item.editedSize : nil,
            keptMotion: keepsMotion(item) ? item.currentMotionSize : 0)
    }

    /// The same, apart from Item: the still kept is the edited one when there is one
    nonisolated static func saving(size: Int64, original: Int64, edited: Int64?, keptMotion: Int64) -> Int64 {
        max(0, size - (edited ?? original) - keptMotion)
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
        let answered = Locked(false)
        return try await withCheckedThrowingContinuation { continuation in
            let options = PHLivePhotoRequestOptions()
            options.version = .current
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestLivePhoto(
                for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .default, options: options
            ) { livePhoto, info in
                // Only the full version, and only once
                guard (info?[PHImageResultIsDegradedKey] as? Bool) != true,
                    answered.update({ answered in defer { answered = true }; return !answered })
                else { return }
                if let livePhoto {
                    continuation.resume(returning: livePhoto)
                } else {
                    continuation.resume(throwing: (info?[PHImageErrorKey] as? Error) ?? FFmpeg.Failure(message: "Photos gave no Live Photo"))
                }
            }
        }
    }

    /// The id a Live Photo's still and motion share: in the still, Apple's maker note, key 17
    nonisolated static func stillPairingID(_ file: URL) -> String? {
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

    /// The photo as HEIC, checked against its JPEG (see Stills)
    nonisolated static func exportHEIC(_ item: Item, to folder: URL) async throws -> Entry {
        let jpeg = try await exportCurrent(item, to: folder)
        let conversion: Stills.Conversion
        do {
            conversion = try Stills.heic(from: jpeg.file, to: jpeg.file.deletingPathExtension().appendingPathExtension("heic"))
        } catch {
            // A refused photo leaves nothing behind: a whole library of them would otherwise wait for the run's end
            try? FileManager.default.removeItem(at: jpeg.file.deletingLastPathComponent())
            throw error
        }
        try? FileManager.default.removeItem(at: jpeg.file)
        return Entry(item: item, file: conversion.file, type: .photo, motion: nil)
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
    /// Returns the new items' ids, in the order of `entries`
    nonisolated static func replace(_ entries: [Entry]) async throws -> [String?] {
        let created = Locked<[String?]>([])
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
                guard let placeholder = request.placeholderForCreatedAsset else {
                    created.update { $0.append(nil) }
                    continue
                }
                created.update { $0.append(placeholder.localIdentifier) }
                itemAlbums.enumerateObjects { album, _, _ in
                    if album.canPerform(.addContent) {
                        PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
                    }
                }
            }
            PHAssetChangeRequest.deleteAssets(entries.map(\.item.asset) as NSArray)
        }
        return created.value
    }

    struct Check {
        var freed: Int64 = 0
        var warnings: [String] = []
    }

    /// Reads the new items back from Photos: what was freed is what the old items held minus what the new ones
    /// hold, and a motion clip where none should be (or none where one should be) is reported. iCloud once
    /// attached a Live Photo's motion back to a still saved byte for byte, which only this would have shown.
    nonisolated static func check(_ entries: [Entry], created ids: [String?]) -> Check {
        var check = Check()
        var assets: [String: PHAsset] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: ids.compactMap { $0 }, options: nil).enumerateObjects { asset, _, _ in
            assets[asset.localIdentifier] = asset
        }
        for (entry, id) in zip(entries, ids) {
            let resources = id.flatMap { assets[$0] }.map { PHAssetResource.assetResources(for: $0) } ?? []
            let stored = resources.reduce(Int64(0)) { $0 + (($1.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0) }
            // A size Photos does not know yet: the files just handed to it
            let kept = stored > 0 ? stored : fileSize(entry.file) + (entry.motion.map(fileSize) ?? 0)
            check.freed += max(0, entry.item.size - kept)
            let hasMotion = resources.contains { $0.type == .pairedVideo || $0.type == .fullSizePairedVideo }
            if !resources.isEmpty, hasMotion != (entry.motion != nil) {
                check.warnings.append(
                    "\(entry.item.filename) (\(hasMotion ? "the new item still holds a motion clip" : "the new item lost its motion"))")
            }
        }
        return check
    }

    nonisolated private static func fileSize(_ file: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
