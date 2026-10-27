import SwiftUI

/// Items as square cards. Click selects one, Cmd-click adds or removes, Shift-click selects a range,
/// double-click opens the item in Photos, right-click shows what can be done to it.
struct GridView: View {
    let items: [Item]
    @Binding var selection: Set<String>
    let actions: Actions
    @State private var anchor: Int?

    /// A right-click acts on the whole selection when the item is part of it, like in Finder
    private func targets(_ item: Item) -> [Item] {
        selection.contains(item.id) ? items.filter { selection.contains($0.id) } : [item]
    }

    var body: some View {
        if items.isEmpty {
            ContentUnavailableView("Nothing here", systemImage: "photo.on.rectangle", description: Text("No items match."))
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 4)], spacing: 4) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        Card(item: item, selected: selection.contains(item.id))
                            .onTapGesture(count: 2) { actions.open(item) }
                            .onTapGesture { click(index) }
                            .contextMenu { ItemMenu(items: targets(item), actions: actions) }
                    }
                }
                .padding(12)
            }
        }
    }

    private func click(_ index: Int) {
        let modifiers = NSEvent.modifierFlags
        let id = items[index].id
        if modifiers.contains(.shift), let anchor, anchor < items.count {
            for item in items[min(anchor, index)...max(anchor, index)] { selection.insert(item.id) }
        } else if modifiers.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
        anchor = index
    }
}

struct Card: View {
    let item: Item
    let selected: Bool

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { Thumbnail(asset: item.asset) }
            .overlay(alignment: .topLeading) {
                if item.favorite { Pill(text: "♥") }
            }
            .overlay(alignment: .topTrailing) { Pill(text: Format.bytes(item.size)) }
            .overlay(alignment: .bottom) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.filename).fontWeight(.semibold).lineLimit(1)
                        Text(Format.date(item.date))
                    }
                    Spacer(minLength: 4)
                    if item.kind == .video { Text(Format.duration(item.duration)) }
                }
                .font(.caption2)
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.top, 16)
                .padding(.bottom, 5)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 3)
                }
            }
            .opacity(selected ? 0.85 : 1)
            .contentShape(Rectangle())
    }
}

struct Pill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
            .padding(6)
    }
}
