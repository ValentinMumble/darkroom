import Foundation

/// The entries of the sidebar: each one a view of the library with its own filter and explanation.
enum Destination: String, CaseIterable, Identifiable, Hashable {
    case videos, photos, similar, live, edited, screenshots, shrinkable, shrinking, favorites

    /// What the main area shows for a destination
    enum Page { case grid, groups, shrinking }

    var id: String { rawValue }

    static let sections = ["Library", "Free up space", "Shrink videos", "Browse"]

    var section: String {
        switch self {
        case .videos, .photos: "Library"
        case .similar, .live, .edited, .screenshots: "Free up space"
        case .shrinkable, .shrinking: "Shrink videos"
        case .favorites: "Browse"
        }
    }

    var page: Page {
        switch self {
        case .similar: .groups
        case .shrinking: .shrinking
        default: .grid
        }
    }

    var label: String {
        switch self {
        case .videos: "Videos"
        case .photos: "Photos"
        case .similar: "Duplicates & Similar"
        case .screenshots: "Screenshots"
        case .shrinkable: "Videos to Shrink"
        case .shrinking: "Shrinking"
        case .favorites: "Favorites"
        case .edited: "Edited"
        case .live: "Live Photos"
        }
    }

    var symbol: String {
        switch self {
        case .videos: "video"
        case .photos: "photo"
        case .similar: "square.on.square"
        case .screenshots: "camera.viewfinder"
        case .shrinkable: "arrow.down.right.and.arrow.up.left"
        case .shrinking: "gearshape.2"
        case .favorites: "heart"
        case .edited: "slider.horizontal.3"
        case .live: "livephoto"
        }
    }

    /// One line under the title, saying what the view is for
    var hint: String {
        switch self {
        case .videos: "Every video in the library. Videos take most of the space: the biggest come first."
        case .photos: "Every photo in the library."
        case .similar:
            "Exact copies first: one of each is kept (a favorite, then an edited one, then the one in more albums) and the rest can go in one click. Then photos taken less than a minute apart that look alike: check each group. Click a shot to see it on the right, click Keep or Delete under it to switch."
        case .screenshots: "Screenshots are rarely worth keeping for long."
        case .shrinkable:
            "Videos that can be re-encoded to a smaller file with ffmpeg. Select some, then Shrink: a copy is kept only if it is at least 20% smaller and looks the same. Edited and slow-motion videos are left out, their copy would lose the edit."
        case .shrinking:
            "Videos being shrunk, one at a time, and the results. Copies go into Photos with the same date, place, favorite and albums. Once you have checked a copy, delete the originals here: that is what frees the space."
        case .favorites: "Favorite photos and videos."
        case .edited:
            "iCloud keeps both the original and the edited version of these. Select some, then Keep Edited Version: the edited version is saved as a new item with the same date, place, favorite and albums, and the original is deleted. The edit can no longer be undone."
        case .live:
            "Live Photos carry a few seconds of video, often bigger than the photo itself. Select some, then Remove Motion: each becomes a still, with its edit, the same date, place, favorite and albums."
        }
    }

    /// Whether the grid of this destination shows an item
    func includes(_ item: Item, shrink: ShrinkStatus) -> Bool {
        switch self {
        case .videos: item.kind == .video
        case .photos: item.kind == .photo
        case .similar, .shrinking: false
        case .screenshots: item.screenshot
        case .shrinkable:
            item.kind == .video && !item.edited && !item.slowMotion && !shrink.shrunk.contains(item.id)
                && !shrink.copies.contains(item.id) && !shrink.kept.contains(item.id)
        case .favorites: item.favorite
        case .edited: item.edited
        case .live: item.live
        }
    }
}

enum Sort: String, CaseIterable, Identifiable {
    case biggest, newest, oldest

    var id: String { rawValue }

    var label: String {
        switch self {
        case .biggest: "Biggest First"
        case .newest: "Newest First"
        case .oldest: "Oldest First"
        }
    }

    func ordered(_ first: Item, _ second: Item) -> Bool {
        switch self {
        case .biggest: first.size > second.size
        case .newest: first.date > second.date
        case .oldest: first.date < second.date
        }
    }
}
