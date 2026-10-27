import AVKit
import Photos
import SwiftUI

/// The right-hand panel: details of the selected item, or a summary of the selection.
struct Inspector: View {
    let items: [Item]
    let actions: Actions

    var body: some View {
        if let item = items.first, items.count == 1 {
            ItemDetail(item: item, actions: actions)
        } else if items.isEmpty {
            ContentUnavailableView(
                "Nothing selected", systemImage: "photo",
                description: Text("Click an item to see it here. Cmd-click or Shift-click to select several."))
        } else {
            VStack(spacing: 12) {
                Text(Format.count(items.count, "item")).font(.title2.weight(.semibold))
                Text(Format.bytes(items.reduce(0) { $0 + $1.size })).foregroundStyle(.secondary)
                ActionButtons(items: items, actions: actions)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// What the toolbar, the inspector and the similar shots can do to items
struct Actions {
    let open: (Item) -> Void
    let changeDate: ([Item]) -> Void
    let setFavorite: ([Item], Bool) -> Void
    let delete: ([Item]) -> Void
    let shrink: ([Item]) -> Void
    let replace: ([Item], Replacement) -> Void
}

/// The right-click menu of an item, acting on `items` (the selection when the item is part of it)
struct ItemMenu: View {
    let items: [Item]
    let actions: Actions

    var body: some View {
        let favorite = items.allSatisfy(\.favorite)
        if let item = items.first, items.count == 1 {
            Button("Open in Photos") { actions.open(item) }
        }
        Button("Change Date…") { actions.changeDate(items) }
        Button(favorite ? "Remove from Favorites" : "Add to Favorites") { actions.setFavorite(items, !favorite) }
        if items.contains(where: { $0.kind == .video }) {
            Button("Shrink…") { actions.shrink(items) }
        }
        if items.contains(where: \.live) {
            Button("Remove Motion…") { actions.replace(items, .removeMotion) }
        }
        if items.contains(where: \.edited) {
            Button("Keep Edited Version Only…") { actions.replace(items, .keepEdit) }
        }
        Divider()
        Button(items.count == 1 ? "Delete…" : "Delete \(items.count) Items…", role: .destructive) {
            actions.delete(items)
        }
    }
}

struct ActionButtons: View {
    let items: [Item]
    let actions: Actions

    var body: some View {
        let favorite = items.allSatisfy(\.favorite)
        VStack(alignment: .leading, spacing: 8) {
            if let item = items.first, items.count == 1 {
                Button("Open in Photos", systemImage: "arrow.up.forward.app") { actions.open(item) }
            }
            Button("Change Date…", systemImage: "calendar") { actions.changeDate(items) }
            Button(favorite ? "Remove from Favorites" : "Add to Favorites", systemImage: favorite ? "heart.slash" : "heart") {
                actions.setFavorite(items, !favorite)
            }
            if items.contains(where: { $0.kind == .video }) {
                Button("Shrink…", systemImage: "arrow.down.right.and.arrow.up.left") { actions.shrink(items) }
            }
            if items.contains(where: \.live) {
                Button("Remove Motion…", systemImage: "livephoto.slash") { actions.replace(items, .removeMotion) }
            }
            if items.contains(where: \.edited) {
                Button("Keep Edited Version Only…", systemImage: "wand.and.stars") { actions.replace(items, .keepEdit) }
            }
            Button("Delete…", systemImage: "trash", role: .destructive) { actions.delete(items) }
        }
        .buttonStyle(.borderless)
    }
}

struct ItemDetail: View {
    let item: Item
    let actions: Actions
    @AppStorage("BlurPhotos") private var blurPhotos = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Group {
                    if item.kind == .video {
                        VideoPreview(asset: item.asset)
                    } else {
                        Thumbnail(asset: item.asset, pixels: 1200, fit: true)
                    }
                }
                .frame(height: 260)
                .frame(maxWidth: .infinity)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Text(item.filename).font(.headline).textSelection(.enabled)

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    Fact("Date", Format.date(item.date))
                    Fact("Size", Format.bytes(item.size) + (item.size != item.originalSize ? " (original \(Format.bytes(item.originalSize)))" : ""))
                    Fact("Dimensions", "\(item.width) × \(item.height)")
                    if item.kind == .video {
                        Fact("Length", Format.duration(item.duration))
                        if item.duration > 0 {
                            Fact("Bitrate", String(format: "%.1f Mbps", Double(item.originalSize) * 8 / 1e6 / item.duration))
                        }
                    }
                    if item.edited { Fact("Edited", "yes, iCloud keeps both versions") }
                    if item.live { Fact("Live Photo", "yes, with a few seconds of video") }
                    if let location = item.location, !blurPhotos {
                        GridRow {
                            Text("Place").foregroundStyle(.secondary)
                            Link(
                                String(format: "%.4f, %.4f", location.coordinate.latitude, location.coordinate.longitude),
                                destination: URL(string: "https://maps.apple.com/?ll=\(location.coordinate.latitude),\(location.coordinate.longitude)")!)
                        }
                    }
                }
                .font(.callout)

                Divider()
                ActionButtons(items: [item], actions: actions)
            }
            .padding()
        }
    }
}

private struct Fact: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

/// Plays a video, streaming it from iCloud when it is not on this Mac.
struct VideoPreview: View {
    let asset: PHAsset
    @State private var player: AVPlayer?
    @AppStorage("BlurPhotos") private var blurPhotos = false

    var body: some View {
        Group {
            if let player, !blurPhotos {
                PlayerView(player: player)
            } else {
                Thumbnail(asset: asset, pixels: 1200, fit: true)
            }
        }
        .task(id: asset.localIdentifier) {
            player = nil
            player = await load()
        }
    }

    /// AVKit's own player view. SwiftUI's VideoPlayer crashes on macOS 27: nothing else references AVKit,
    /// so the framework is never loaded and its player class cannot be found at runtime.
    private struct PlayerView: NSViewRepresentable {
        let player: AVPlayer

        func makeNSView(context: Context) -> AVPlayerView {
            let view = AVPlayerView()
            view.controlsStyle = .inline
            view.player = player
            return view
        }

        func updateNSView(_ view: AVPlayerView, context: Context) {
            view.player = player
        }

        static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
            view.player?.pause()
        }
    }

    private func load() async -> AVPlayer? {
        await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .automatic
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                continuation.resume(returning: item.map(AVPlayer.init(playerItem:)))
            }
        }
    }
}
