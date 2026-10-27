import SwiftUI

struct ReplaceRequest: Identifiable {
    let id = UUID()
    let items: [Item]
    let kind: Replacement
}

/// Remove Motion and Keep Edited Version: what will happen, the choices that matter, then the progress.
struct ReplaceSheet: View {
    let request: ReplaceRequest
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var keepFavorites = true
    @State private var includeLive = false
    @State private var message: String?
    @State private var done = 0
    @State private var outcome: Library.ReplaceOutcome?

    private var kind: Replacement { request.kind }

    private var targets: [Item] {
        request.items.filter { item in
            kind.applies(to: item)
                && !(kind == .removeMotion && keepFavorites && item.favorite)
                && !(kind == .keepEdit && item.live && !includeLive)
        }
    }

    var body: some View {
        let targets = targets
        let saving = targets.reduce(0) { $0 + Replacement.saving($1) }
        VStack(alignment: .leading, spacing: 14) {
            Text("\(kind.title): \(Format.count(targets.count, "item")), frees about \(Format.bytes(saving))")
                .font(.title2.weight(.semibold))
            if kind == .removeMotion {
                Text(
                    "Each Live Photo is replaced by its still, as it looks now (with its edit), with the same date, place, favorite and albums. The motion is gone for good once Recently Deleted is emptied."
                )
                Toggle("Leave favorites as Live Photos", isOn: $keepFavorites)
            } else {
                Text(
                    "Each item is replaced by its edited version alone, with the same date, place, favorite and albums. The edit can no longer be undone, and the original is gone for good once Recently Deleted is emptied."
                )
                Toggle("Include edited Live Photos (they become stills, without motion)", isOn: $includeLive)
            }
            Text(
                "Names of people tagged in these items need tagging again. macOS asks you to confirm each batch of up to 200, and nothing changes in a batch you refuse. Deleted items stay in Recently Deleted for 30 days, where they still count against iCloud."
            )
            .foregroundStyle(.secondary)

            if let outcome {
                Text(summary(outcome)).fontWeight(.medium)
            } else if let message {
                ProgressView(value: Double(done), total: Double(max(targets.count, 1))) {
                    Text("\(message) \(done) of \(targets.count)")
                }
            }

            HStack {
                Spacer()
                if outcome != nil {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(message != nil)
                    Button(kind.title) { start(targets) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(targets.isEmpty || message != nil)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .interactiveDismissDisabled(message != nil && outcome == nil)
    }

    private func start(_ targets: [Item]) {
        message = "Starting…"
        Task {
            outcome = await library.replace(targets, kind: kind) { text, count in
                message = text
                done = count
            }
        }
    }

    private func summary(_ outcome: Library.ReplaceOutcome) -> String {
        var parts = ["\(Format.count(outcome.replaced, "item")) replaced, \(Format.bytes(outcome.freed)) freed once Recently Deleted is emptied."]
        if outcome.cancelled { parts.append("You refused a deletion, so that batch and the ones after it were left as they were.") }
        if !outcome.failed.isEmpty {
            parts.append("Could not get from Photos: \(outcome.failed.prefix(5).joined(separator: ", "))\(outcome.failed.count > 5 ? "…" : "").")
        }
        return parts.joined(separator: " ")
    }
}
