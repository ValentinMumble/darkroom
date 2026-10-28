import Foundation

/// The entries of the sidebar: each one a view of the library with its own filter and explanation.
enum Destination: String, CaseIterable, Identifiable, Hashable {
    case videos, photos, similar, live, lifeless, hiddenMotion, edited, rotated, screenshots, shrinking, favorites

    /// What the main area shows for a destination
    enum Page { case grid, groups, shrinking }

    var id: String { rawValue }

    static let sections = ["Library", "Free up space", "Browse"]

    var section: String {
        switch self {
        case .videos, .photos: "Library"
        case .similar, .live, .lifeless, .hiddenMotion, .edited, .rotated, .screenshots, .shrinking: "Free up space"
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
        case .shrinking: "Shrinking"
        case .favorites: "Favorites"
        case .edited: "Edited"
        case .rotated: "Only Rotated"
        case .live: "Live Photos"
        case .lifeless: "No People or Pets"
        case .hiddenMotion: "Hidden Motion"
        }
    }

    var symbol: String {
        switch self {
        case .videos: "video"
        case .photos: "photo"
        case .similar: "square.on.square"
        case .screenshots: "camera.viewfinder"
        case .shrinking: "gearshape.2"
        case .favorites: "heart"
        case .edited: "slider.horizontal.3"
        case .rotated: "rotate.right"
        case .live: "livephoto"
        case .lifeless: "mountain.2"
        case .hiddenMotion: "eye.slash"
        }
    }

    /// One line under the title, saying what the view is for
    var hint: String {
        switch self {
        case .videos:
            "Every video in the library. Videos take most of the space: the biggest come first. Select some, then Shrink to re-encode them to a smaller file with ffmpeg: a copy is kept only if it is at least 20% smaller and looks the same. An edited video (rotated, trimmed) is shrunk as it looks now. Slow-motion videos are left out: their copy would lose the slow motion."
        case .photos: "Every photo in the library."
        case .similar:
            "Exact copies first: one of each is kept (a favorite, then an edited one, then the one in more albums) and the rest can go in one click. Then photos taken less than a minute apart that look alike: check each group. Click a shot to see it on the right, click Keep or Delete under it to switch."
        case .screenshots: "Screenshots are rarely worth keeping for long."
        case .shrinking:
            "Videos being shrunk, one at a time, and the results. Copies go into Photos with the same date, place, favorite and albums. Once you have checked a copy, delete the originals here: that is what frees the space. A copy refused for its quality waits here too: compare it with the original and save it anyway if it looks fine."
        case .favorites: "Favorite photos and videos."
        case .edited:
            "iCloud keeps both the original and the edited version of these. Select some, then Keep Edited Version: the edited version is saved as a new item with the same date, place, favorite and albums, and the original is deleted. A Live Photo stays a Live Photo, with its edited motion. The edit can no longer be undone."
        case .rotated:
            "Edits that only rotate an item, or change nothing at all: iCloud still keeps the original under them, a full extra copy. Select some, then Keep Edited Version: the rotated version is saved as a new item with the same date, place, favorite and albums, and the original is deleted. A Live Photo stays a Live Photo, with its rotated motion."
        case .hiddenMotion:
            "Stills that still store the motion clip of the Live Photo they came from, though Photos no longer plays it, so iCloud still counts it. Select them, then Remove Motion: each is saved again as a new file, and iCloud lets go of the clip."
        case .lifeless:
            "Live Photos where Vision, on this Mac, found no person, face, cat or dog: landscapes, food, things, where the motion rarely adds much. Select some, then Remove Motion: each becomes a still, with its edit, the same date, place, favorite and albums. It can miss someone small or turned away, so look before removing."
        case .live:
            "Live Photos carry a few seconds of video, often bigger than the photo itself. Select some, then Remove Motion: each becomes a still, with its edit, the same date, place, favorite and albums."
        }
    }

    /// What the toolbar's main button does here, and what the sidebar counts it would free
    var replacement: Replacement? {
        switch self {
        case .live, .lifeless, .hiddenMotion: .removeMotion
        case .edited, .rotated: .keepEdit
        default: nil
        }
    }

    /// Whether the grid of this destination shows an item
    /// `lifeless`: Live Photos where Vision found nobody (see Subjects)
    func includes(_ item: Item, shrink: ShrinkStatus, lifeless: Set<String> = []) -> Bool {
        switch self {
        case .videos: item.kind == .video
        case .photos: item.kind == .photo
        case .similar, .shrinking: false
        case .screenshots: item.screenshot
        case .favorites: item.favorite
        case .edited: Replacement.keepEdit.applies(to: item)
        case .rotated: item.onlyRotated
        case .live: item.live
        case .lifeless: item.live && lifeless.contains(item.id)
        case .hiddenMotion: item.hiddenMotion
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
