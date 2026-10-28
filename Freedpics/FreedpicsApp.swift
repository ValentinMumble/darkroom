import SwiftUI

@main
struct FreedpicsApp: App {
    @State private var library: Library
    @State private var shrinker: Shrinker

    init() {
        let library = Library()
        _library = State(initialValue: library)
        _shrinker = State(initialValue: Shrinker(library: library))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .environment(shrinker)
        }
        // A fixed minimum size here fights the split view's own column sizes and loops the layout
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Reload Library") { Task { await library.reload() } }
                    .keyboardShortcut("r")
            }
        }
    }
}
