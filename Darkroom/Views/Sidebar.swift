import SwiftUI

struct Sidebar: View {
    @Environment(Library.self) private var library
    @Environment(Shrinker.self) private var shrinker
    @Binding var destination: Destination?

    var body: some View {
        List(selection: $destination) {
            if let storage = library.storage {
                Section("iCloud") { StorageView(storage: storage, library: library) }
            }
            ForEach(Destination.sections, id: \.self) { section in
                Section(section) {
                    ForEach(Destination.allCases.filter { $0.section == section }) { entry in
                        // A badge keeps the row's width fixed while the counts change
                        Label(entry.label, systemImage: entry.symbol)
                            .badge(Text(tally(entry)))
                            .tag(entry)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func tally(_ entry: Destination) -> String {
        if entry == .similar {
            let copies = library.duplicateGroups.reduce(0) { $0 + $1.itemIds.count - 1 }
            let similar = library.similarGroups.map { ", \(Format.count($0.count, "group"))" } ?? ""
            return "\(copies == 1 ? "1 copy" : "\(copies.formatted()) copies")\(similar)"
        }
        if entry == .shrinking {
            if shrinker.running > 0 { return "\(shrinker.running) running" }
            let originals = library.shrinkRecords.values.filter { $0.copy != nil && library.itemsById[$0.original] != nil }
            return originals.isEmpty ? "" : "\(originals.count) to delete"
        }
        guard let tally = library.tallies[entry], tally.count > 0 else { return "0" }
        // Where a replacement applies, what it would free matters more than the size
        if entry == .live || entry == .edited {
            return "\(tally.count.formatted()) · −\(Format.bytes(tally.saving))"
        }
        return "\(tally.count.formatted()) · \(Format.bytes(tally.size))"
    }
}

/// iCloud storage by app, like System Settings shows it, plus the library's own size.
struct StorageView: View {
    let storage: ICloudStorage
    let library: Library

    private static let colors: [Color] = [.blue, .orange, .cyan, .green]

    private struct Part: Identifiable {
        let label: String
        let size: Int64
        let color: Color
        var id: String { label }
    }

    private var parts: [Part] {
        let named = storage.apps.prefix(Self.colors.count)
        let others = storage.apps.dropFirst(Self.colors.count).reduce(0) { $0 + $1.size }
        var parts = named.enumerated().map { index, app in Part(label: app.label, size: app.size, color: Self.colors[index]) }
        if others > 0 {
            parts.append(Part(label: "\(storage.apps.count - named.count) other apps", size: others, color: .purple))
        }
        return parts
    }

    /// Space used now. The split by app is macOS's last copy and can lag; the free space is live.
    private var used: Int64 {
        guard let total = storage.total, let free = storage.free else { return storage.used }
        return total - free
    }

    var body: some View {
        // What changed since macOS last fetched the split by app: positive when space was freed
        let freedSince = storage.used - used
        // Shrink the parts to what is used now, so the bar matches the live free space
        let scale = storage.used > 0 ? min(1, Double(used) / Double(storage.used)) : 1
        VStack(alignment: .leading, spacing: 6) {
            if let total = storage.total {
                HStack {
                    Text("\(Format.bytes(used)) of \(Format.bytes(total)) used")
                    Spacer()
                }
                .font(.callout)
                // Drawn rather than laid out: measuring inside a sidebar row can loop the window's layout
                Canvas { context, size in
                    var x = 0.0
                    for part in parts {
                        let width = size.width * Double(part.size) * scale / Double(total)
                        context.fill(Path(CGRect(x: x, y: 0, width: width, height: size.height)), with: .color(part.color))
                        x += width
                    }
                }
                .frame(height: 8)
                .background(.quaternary)
                .clipShape(Capsule())
            }
            ForEach(parts) { part in
                HStack(spacing: 6) {
                    Circle().fill(part.color).frame(width: 8, height: 8)
                    Text(part.label)
                    Spacer()
                    Text(Format.bytes(part.size)).foregroundStyle(.secondary)
                }
            }
            if let free = storage.free {
                HStack(spacing: 6) {
                    Circle().strokeBorder(.secondary).frame(width: 8, height: 8)
                    Text("Free")
                    Spacer()
                    Text(Format.bytes(free)).fontWeight(.semibold)
                }
            }
            if let fetchedAt = storage.fetchedAt {
                // Ignore small drifts: photos keep syncing
                if abs(freedSince) > 100 << 20 {
                    HStack(spacing: 6) {
                        Image(systemName: freedSince > 0 ? "arrow.down.circle" : "arrow.up.circle").frame(width: 8)
                        Text(freedSince > 0 ? "Freed since \(Format.time(fetchedAt))" : "Added since \(Format.time(fetchedAt))")
                        Spacer()
                        Text(Format.bytes(abs(freedSince))).foregroundStyle(freedSince > 0 ? .green : .secondary)
                    }
                }
                Text("By app as of \(Format.time(fetchedAt)) · free space live")
                    .foregroundStyle(.tertiary)
                    .help("macOS fetches the split by app from Apple now and then; the free space is read every minute")
            }
        }
        .font(.caption)
        .padding(.vertical, 4)
    }
}
