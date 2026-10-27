import CoreLocation
import Photos

/// A photo or video of the library, with what PhotoKit only tells through its resources.
struct Item: Identifiable, Hashable {
    enum Kind { case photo, video }

    let id: String
    let asset: PHAsset
    let kind: Kind
    let date: Date
    let filename: String
    /// Bytes iCloud stores for it: the original, the motion of a Live Photo, saved edits
    let size: Int64
    let originalSize: Int64
    let editedSize: Int64
    let motionSize: Int64
    let width: Int
    let height: Int
    let duration: TimeInterval
    let favorite: Bool
    let edited: Bool
    let screenshot: Bool
    let live: Bool
    let slowMotion: Bool
    let location: CLLocation?

    init(asset: PHAsset, resources: Resources) {
        id = asset.localIdentifier
        self.asset = asset
        kind = asset.mediaType == .video ? .video : .photo
        date = asset.creationDate ?? .distantPast
        filename = resources.filename
        size = resources.size
        originalSize = resources.originalSize
        editedSize = resources.editedSize
        motionSize = resources.motionSize
        width = asset.pixelWidth
        height = asset.pixelHeight
        duration = asset.duration
        favorite = asset.isFavorite
        edited = resources.edited
        screenshot = asset.mediaSubtypes.contains(.photoScreenshot)
        live = asset.mediaSubtypes.contains(.photoLive)
        slowMotion = asset.mediaSubtypes.contains(.videoHighFrameRate)
        location = asset.location
    }

    /// The uuid Photos uses in links: the local identifier without its "/L0/001" suffix
    var uuid: String { String(id.prefix { $0 != "/" }) }

    /// Items imported twice share this: same moment, dimensions and original size. Without a known size,
    /// burst shots of the same second would match, so those items never count as duplicates.
    var duplicateKey: String? {
        originalSize > 0 ? "\(Int(date.timeIntervalSince1970))-\(width)x\(height)-\(originalSize)" : nil
    }

    static func == (first: Item, second: Item) -> Bool {
        first.id == second.id && first.date == second.date && first.favorite == second.favorite
            && first.size == second.size
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// The files behind an asset. Reading them costs a database query per asset, so the library caches them.
struct Resources {
    let filename: String
    let size: Int64
    let originalSize: Int64
    /// The edited photo or video Photos rendered, 0 when not edited
    let editedSize: Int64
    /// A Live Photo's motion clips: the original and, after an edit, the re-rendered one
    let motionSize: Int64
    let edited: Bool

    init(asset: PHAsset) {
        let resources = PHAssetResource.assetResources(for: asset)
        var filename = ""
        var size: Int64 = 0
        var originalSize: Int64 = 0
        var editedSize: Int64 = 0
        var motionSize: Int64 = 0
        var edited = false
        for resource in resources {
            // Not public API, but the only way to know a resource's size without downloading it
            let bytes = (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0
            size += bytes
            switch resource.type {
            case .photo, .video:
                if filename.isEmpty {
                    filename = resource.originalFilename
                    originalSize = bytes
                }
            case .fullSizePhoto, .fullSizeVideo:
                edited = true
                editedSize += bytes
            case .adjustmentData:
                edited = true
            case .pairedVideo, .fullSizePairedVideo, .adjustmentBasePairedVideo:
                motionSize += bytes
            default:
                break
            }
        }
        self.filename = filename.isEmpty ? (resources.first?.originalFilename ?? "") : filename
        self.size = size
        self.originalSize = originalSize
        self.editedSize = editedSize
        self.motionSize = motionSize
        self.edited = edited
    }
}
