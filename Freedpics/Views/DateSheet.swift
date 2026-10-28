import SwiftUI

struct DateRequest: Identifiable {
    let id = UUID()
    let items: [Item]
}

struct DateSheet: View {
    let items: [Item]
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    private enum Mode: String, CaseIterable, Identifiable {
        case move, set, shift, filename
        var id: String { rawValue }
        var label: String {
            switch self {
            case .move: "Move: the earliest gets this date, the others keep their spacing"
            case .set: "Set every item to this exact date"
            case .shift: "Shift by an amount of time"
            case .filename: "Read the date from the file name"
            }
        }
    }

    private let sorted: [Item]
    @State private var mode: Mode
    @State private var target: Date
    @State private var days = 0
    @State private var hours = 0
    @State private var minutes = 0
    @State private var pattern = "%Y%m%d_%H%M%S"
    @State private var saving = false

    init(items: [Item]) {
        self.items = items
        sorted = items.sorted { $0.date < $1.date }
        _mode = State(initialValue: items.count > 1 ? .move : .set)
        _target = State(initialValue: sorted.first?.date ?? .now)
    }

    private var change: DateChange {
        switch mode {
        case .move: .move(to: target)
        case .set: .set(to: target)
        case .shift: .shift(by: TimeInterval(((days * 24 + hours) * 60 + minutes) * 60))
        case .filename: .fromFilename(pattern: pattern)
        }
    }

    private var changes: [(Item, Date)] {
        let earliest = sorted.first?.date ?? .now
        return sorted.compactMap { item in change.newDate(for: item, earliest: earliest).map { (item, $0) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Picker("Change", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)

                switch mode {
                case .move, .set:
                    DatePicker("Date and time", selection: $target)
                case .shift:
                    Stepper("Days: \(days)", value: $days)
                    Stepper("Hours: \(hours)", value: $hours)
                    Stepper("Minutes: \(minutes)", value: $minutes)
                case .filename:
                    TextField("Pattern", text: $pattern)
                    Text("Codes %Y %m %d %H %M %S, matched anywhere in the name. %Y%m%d_%H%M%S reads IMG_20240714_183000 and PXL_20240714_183000123; %Y%m%d-WA reads WhatsApp names (date only).")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Preview") {
                    let earliest = sorted.first?.date ?? .now
                    ForEach(sorted.prefix(8)) { item in
                        LabeledContent(item.filename) {
                            let next = change.newDate(for: item, earliest: earliest)
                            Text("\(Format.date(item.date)) → \(next.map(Format.date) ?? "no match")")
                                .foregroundStyle(next == nil ? .secondary : .primary)
                        }
                    }
                    if sorted.count > 8 { Text("and \(sorted.count - 8) more").foregroundStyle(.secondary) }
                }
            }
            .formStyle(.grouped)

            HStack {
                Text("\(changes.count) of \(items.count) will change").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    saving = true
                    Task {
                        await library.setDates(changes)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(changes.isEmpty || saving)
            }
            .padding()
        }
        .frame(width: 560, height: 520)
    }
}
