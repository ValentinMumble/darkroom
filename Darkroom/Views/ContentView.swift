import SwiftUI

struct ContentView: View {
    @Environment(Library.self) private var library
    @Environment(Shrinker.self) private var shrinker
    // For screenshots: open --args -StartDestination similar -SelectFirst YES
    @State private var destination: Destination? =
        Destination(rawValue: UserDefaults.standard.string(forKey: "StartDestination") ?? "") ?? .videos
    @State private var selection: Set<String> = []
    @State private var sort: Sort = .biggest
    @State private var year = 0
    @State private var search = ""
    @State private var showInspector = true
    @State private var dateRequest: DateRequest?
    @State private var shrinkRequest: ShrinkRequest?
    @State private var replaceRequest: ReplaceRequest?
    @State private var keyMonitor: Any?
    @AppStorage("VideosNotShrunkOnly") private var notShrunkOnly = false

    private var current: Destination { destination ?? .videos }

    /// The destination's items, before the year and search filters
    private func listed(_ item: Item) -> Bool {
        current.includes(item, shrink: library.shrinkStatus, lifeless: library.lifeless ?? [])
            && (current != .videos || !notShrunkOnly || library.shrinkUntried(item))
    }

    private var shown: [Item] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return library.items
            .filter { item in
                listed(item)
                    && (year == 0 || Calendar.current.component(.year, from: item.date) == year)
                    && (query.isEmpty || item.filename.lowercased().contains(query))
            }
            .sorted(by: sort.ordered)
    }

    private var selected: [Item] {
        library.items.filter { selection.contains($0.id) }
    }

    private var years: [Int] {
        let years = library.items.filter(listed)
            .map { Calendar.current.component(.year, from: $0.date) }
        return Array(Set(years)).sorted(by: >)
    }

    private var actions: Actions {
        Actions(
            open: { item in
                // AppleScript's spotlight command crashes Photos on macOS 27; this link does not
                NSWorkspace.shared.open(URL(string: "photos-navigation://asset?uuid=\(item.uuid)")!)
            },
            changeDate: { items in dateRequest = DateRequest(items: items) },
            setFavorite: { items, favorite in Task { await library.setFavorite(items, favorite) } },
            delete: { items in Task { await library.delete(items) } },
            shrink: { items in shrinkRequest = ShrinkRequest(items: items) },
            replace: { items, kind in replaceRequest = ReplaceRequest(items: items, kind: kind) }
        )
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(destination: $destination)
                .navigationSplitViewColumnWidth(min: 240, ideal: 270)
        } detail: {
            detail
                .navigationTitle(current.label)
                .navigationSubtitle(subtitle)
                // Small minimums: when the columns' minimums add up to more than the window, resizing a column
                // makes the split view and the grid fight over the width, and the layout never settles
                .navigationSplitViewColumnWidth(min: 300, ideal: 800)
        }
        .inspector(isPresented: $showInspector) {
            Inspector(items: selected, actions: actions)
                .inspectorColumnWidth(min: 260, ideal: 320, max: 480)
        }
        .toolbar { toolbar }
        .searchable(text: $search, placement: .toolbar, prompt: "File name")
        .sheet(item: $dateRequest) { request in DateSheet(items: request.items) }
        .sheet(item: $replaceRequest) { request in ReplaceSheet(request: request) }
        .sheet(item: $shrinkRequest) { request in
            ShrinkSheet(items: request.items) { items, preset in
                shrinker.enqueue(items, preset: preset)
                destination = .shrinking
            }
        }
        .onChange(of: library.state) {
            if library.state == .ready, selection.isEmpty, UserDefaults.standard.bool(forKey: "SelectFirst"),
                let first = shown.first
            {
                selection = [first.id]
            }
        }
        .onChange(of: destination) {
            selection = []
            year = 0
        }
        .alert("Photos refused the change", isPresented: errorShown) {
            Button("OK") { library.error = nil }
        } message: {
            Text(library.error ?? "")
        }
        .task { await library.start() }
        // Cmd-A selects every item shown. The Edit menu's Select All only reaches text fields, so the key is
        // caught before it, except while typing in a field or with a sheet open.
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                    event.charactersIgnoringModifiers == "a", current.page == .grid,
                    let window = NSApp.keyWindow, window.sheetParent == nil, !(window.firstResponder is NSText)
                else { return event }
                selection = Set(shown.map(\.id))
                return nil
            }
        }
        .onDisappear { keyMonitor.map(NSEvent.removeMonitor) }
        // Free space changes with anything stored in iCloud: read it again every minute and on coming back
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await library.refreshStorage()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await library.refreshStorage() }
        }
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })
    }

    private var subtitle: String {
        guard library.state == .ready, current.page == .grid else { return "" }
        let items = shown
        return "\(Format.count(items.count, "item")), \(Format.bytes(items.reduce(0) { $0 + $1.size }))"
    }

    @ViewBuilder private var detail: some View {
        switch library.state {
        case .starting:
            ProgressView()
        case .denied:
            ContentUnavailableView(
                "No access to Photos", systemImage: "lock",
                description: Text("Allow Darkroom in System Settings › Privacy & Security › Photos, then open it again."))
        case .loading(let done, let total):
            ProgressView(value: Double(done), total: Double(max(total, 1))) {
                Text("Reading \(total.formatted()) items from Photos…")
            }
            .padding(40)
        case .ready:
            VStack(alignment: .leading, spacing: 0) {
                Text(current.hint)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                switch current.page {
                case .groups: GroupsView(selection: $selection, actions: actions)
                case .shrinking: ShrinkView(actions: actions)
                case .grid where current == .lifeless && library.lifeless == nil:
                    ProgressView(value: library.subjectsProgress) {
                        Text("Looking for people and pets in each Live Photo…")
                    }
                    .padding(40)
                    .task { await library.findSubjects() }
                case .grid: GridView(items: shown, selection: $selection, actions: actions)
                }
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        let videos = selected.filter { $0.kind == .video }.count
        let shrinkable = selected.filter { library.shrinkSkip($0) == nil }.count
        let live = selected.filter(\.live).count
        let edited = selected.filter(Replacement.keepEdit.applies).count
        if current == .live || current == .lifeless || (live > 0 && current != .edited && current != .rotated) {
            ToolbarItem {
                Button {
                    actions.replace(selected, .removeMotion)
                } label: {
                    Label(live == 0 ? "Remove Motion" : "Remove Motion from \(live)", systemImage: "livephoto.slash")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .disabled(live == 0)
                .help(live == 0 ? "Select Live Photos" : "Replace the selected Live Photos by their stills")
            }
        }
        if current == .edited || current == .rotated {
            ToolbarItem {
                Button {
                    actions.replace(selected, .keepEdit)
                } label: {
                    Label(edited == 0 ? "Keep Edited Version" : "Keep Edited Version of \(edited)", systemImage: "wand.and.stars")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .disabled(edited == 0)
                .help(edited == 0 ? "Select edited items" : "Replace the selected items by their edited version alone")
            }
        }
        if current == .videos || (videos > 0 && current != .live && current != .edited && current != .rotated) {
            ToolbarItem {
                Button {
                    actions.shrink(selected)
                } label: {
                    Label(shrinkable == 0 ? "Shrink" : "Shrink \(Format.count(shrinkable, "Video"))", systemImage: "arrow.down.right.and.arrow.up.left")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .disabled(shrinkable == 0)
                .help(
                    shrinkable > 0
                        ? "Shrink the selected videos"
                        : selected.compactMap { library.shrinkSkip($0) }.first.map { "Cannot shrink: \($0)" } ?? "Select videos to shrink")
            }
        }
        ToolbarItemGroup {
            if current.page == .grid {
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.label).tag($0) }
                }
                Picker("Year", selection: $year) {
                    Text("All Years").tag(0)
                    ForEach(years, id: \.self) { Text(String($0)).tag($0) }
                }
                if current == .videos {
                    Picker("Show", selection: $notShrunkOnly) {
                        Text("All Videos").tag(false)
                        Text("Not Shrunk Yet").tag(true)
                    }
                    .help("Not Shrunk Yet hides shrunk copies, originals that have one, videos tried before and slow-motion videos")
                }
                Button("Select All", systemImage: "checkmark.circle") { selection = Set(shown.map(\.id)) }
                    .help("Select every item shown (Cmd-A)")
            }
        }
        ToolbarItemGroup {
            let favorite = !selected.isEmpty && selected.allSatisfy(\.favorite)
            Button("Favorite", systemImage: favorite ? "heart.fill" : "heart") {
                actions.setFavorite(selected, !favorite)
            }
            .disabled(selected.isEmpty)
            Button("Change Date", systemImage: "calendar") { actions.changeDate(selected) }
                .disabled(selected.isEmpty)
            Button("Open in Photos", systemImage: "arrow.up.forward.app") { selected.first.map(actions.open) }
                .disabled(selected.count != 1)
            Button("Delete", systemImage: "trash") { actions.delete(selected) }
                .disabled(selected.isEmpty)
                .keyboardShortcut(.delete, modifiers: .command)
            Button("Details", systemImage: "info.circle") { showInspector.toggle() }
        }
    }
}
