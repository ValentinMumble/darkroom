import Charts
import SwiftUI

/// What Freedpics saved, day by day and by kind of change, and iCloud's free space read along the way.
struct SavingsSheet: View {
    let library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var selectedDay: Date?

    private static let gib = Double(1 << 30)

    var body: some View {
        let savings = library.savings
        let days = Savings.daily(savings)
        let kinds = Saving.Kind.allCases.filter { kind in days.contains { $0.kind == kind } }
        VStack(alignment: .leading, spacing: 14) {
            Text("Saved with Freedpics: \(Format.bytes(savings.reduce(0) { $0 + $1.bytes }))")
                .font(.title2.weight(.semibold))
            if let first = savings.first {
                Text("Since \(first.date.formatted(date: .abbreviated, time: .omitted)), counted when each change is made.")
                    .foregroundStyle(.secondary)
            }

            Text("Saved per day").font(.headline)
            Chart {
                ForEach(days) { day in
                    BarMark(x: .value("Day", day.day, unit: .day), y: .value("Saved", Double(day.bytes) / Self.gib), width: .ratio(0.6))
                        .foregroundStyle(by: .value("Change", day.kind.label))
                }
                if let selectedDay {
                    RuleMark(x: .value("Day", selectedDay, unit: .day))
                        .foregroundStyle(.secondary.opacity(0.4))
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            dayDetail(selectedDay, days)
                        }
                }
            }
            // Each kind keeps its color, whichever kinds are shown
            .chartForegroundStyleScale(domain: kinds.map(\.label), range: kinds.map(\.color))
            .chartYAxis { gigabytes }
            .chartXSelection(value: $selectedDay)
            .frame(height: 220)

            table(savings)

            Text("iCloud free space").font(.headline)
            iCloud

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
    }

    private var gigabytes: some AxisContent {
        AxisMarks { value in
            AxisGridLine().foregroundStyle(.quaternary)
            AxisValueLabel { Text(Format.bytes(Int64((value.as(Double.self) ?? 0) * Self.gib))) }
        }
    }

    /// The hovered day, change by change
    private func dayDetail(_ day: Date, _ days: [Savings.Day]) -> some View {
        let entries = days.filter { Calendar.current.isDate($0.day, inSameDayAs: day) }
        return VStack(alignment: .leading, spacing: 2) {
            Text(day.formatted(date: .abbreviated, time: .omitted)).fontWeight(.semibold)
            ForEach(entries) { entry in
                HStack(spacing: 6) {
                    Circle().fill(entry.kind.color).frame(width: 8, height: 8)
                    Text(entry.kind.label)
                    Spacer()
                    Text(Format.bytes(entry.bytes))
                }
            }
            if entries.count > 1 {
                Text("Total \(Format.bytes(entries.reduce(0) { $0 + $1.bytes }))").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(8)
        .frame(width: 210)
        .background(.background, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
    }

    /// The same numbers as the chart, by kind, readable without telling the colors apart
    private func table(_ savings: [Saving]) -> some View {
        let byKind = Dictionary(grouping: savings, by: \.kind)
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(Saving.Kind.allCases.filter { byKind[$0] != nil }, id: \.self) { kind in
                let entries = byKind[kind] ?? []
                GridRow {
                    HStack(spacing: 6) {
                        Circle().fill(kind.color).frame(width: 8, height: 8)
                        Text(kind.label)
                    }
                    Text(Format.count(entries.reduce(0) { $0 + $1.count }, kind.noun)).foregroundStyle(.secondary)
                    Text(Format.bytes(entries.reduce(0) { $0 + $1.bytes })).gridColumnAlignment(.trailing)
                }
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private var iCloud: some View {
        let readings = library.storageReadings
        if readings.count > 1 {
            Chart(readings, id: \.date) { reading in
                LineMark(x: .value("Time", reading.date), y: .value("Free", Double(reading.free) / Self.gib))
                    .interpolationMethod(.stepEnd)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            .chartYAxis { gigabytes }
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 140)
        }
        if let comparison = Savings.comparison(library.savings, readings) {
            let change =
                comparison.freed >= 0 ? "went up \(Format.bytes(comparison.freed))" : "went down \(Format.bytes(-comparison.freed))"
            Text(
                "Since \(Format.date(comparison.since)), iCloud's free space \(change), and Freedpics counted \(Format.bytes(comparison.counted)). The free space also moves with everything else in iCloud: backups, other apps, new photos."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Read once an hour from now on, to compare with what Freedpics counts.")
                .foregroundStyle(.secondary)
        }
    }
}

extension Saving.Kind {
    /// One fixed color per kind, checked for color blindness side by side, a step darker or lighter in dark mode
    var color: Color {
        let (light, dark): (UInt32, UInt32) =
            switch self {
            case .deleted: (0x2a78d6, 0x3987e5)
            case .removedMotion: (0xeb6834, 0xd95926)
            case .keptEdit: (0x1baf7a, 0x199e70)
            case .shrunk: (0xeda100, 0xc98500)
            case .convertedToHEIC: (0xe87ba4, 0xd55181)
            case .deletedFiles: (0x008300, 0x008300)
            }
        return Color(
            nsColor: NSColor(name: nil) { appearance in
                let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
                return NSColor(
                    srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255,
                    alpha: 1)
            })
    }
}
