import Photos
import SwiftUI

/// An item's picture from Photos, downloaded from iCloud when needed. Fills its frame, or fits with `fit`.
struct Thumbnail: View {
    let asset: PHAsset
    var pixels: CGFloat = 320
    var fit = false
    /// The picture as taken, before any edit
    var original = false
    @State private var image: NSImage?
    /// For screenshots of the app: `defaults write com.valentinmumble.darkroom BlurPhotos -bool YES`
    @AppStorage("BlurPhotos") private var blurPhotos = false

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: fit ? .fit : .fill)
                    .blur(radius: blurPhotos ? 14 : 0, opaque: true)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .task(id: "\(asset.localIdentifier)-\(pixels)-\(original)") {
            for await next in Thumbnails.images(for: asset, pixels: pixels, fill: !fit, original: original) {
                image = next
            }
        }
    }
}

enum Thumbnails {
    static let manager = PHCachingImageManager()

    /// A quick low-resolution image first, then the sharp one
    static func images(for asset: PHAsset, pixels: CGFloat, fill: Bool, original: Bool = false) -> AsyncStream<NSImage> {
        AsyncStream { continuation in
            let options = PHImageRequestOptions()
            options.version = original ? .original : .current
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            let request = manager.requestImage(
                for: asset, targetSize: CGSize(width: pixels, height: pixels),
                contentMode: fill ? .aspectFill : .aspectFit, options: options
            ) { image, info in
                if let image { continuation.yield(image) }
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !degraded { continuation.finish() }
            }
            continuation.onTermination = { _ in manager.cancelImageRequest(request) }
        }
    }
}
