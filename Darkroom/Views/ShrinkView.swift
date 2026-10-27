import SwiftUI

/// The shrink jobs of this session, every result so far, and the originals that can now go.
struct ShrinkView: View {
    @Environment(Library.self) private var library
    @Environment(Shrinker.self) private var shrinker
    let actions: Actions

    var body: some View {
        let records = library.shrinkRecords.values.sorted { $0.date > $1.date }
        // Originals whose copy is in Photos and which are still there
        let originals = records.filter { $0.copy != nil }.compactMap { library.itemsById[$0.original] }
        let saved = records.filter { $0.copy != nil }.reduce(0) { $0 + $1.before - $1.after }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(Format.count(records.filter { $0.copy != nil }.count, "video")) shrunk, \(Format.bytes(saved)) saved once the originals are deleted")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Delete \(Format.count(originals.count, "Original")) (\(Format.bytes(originals.reduce(0) { $0 + $1.size })))…", role: .destructive) {
                        actions.delete(originals)
                    }
                    .disabled(originals.isEmpty)
                }

                if !shrinker.jobs.isEmpty {
                    HStack {
                        Text("This session").font(.title3.weight(.semibold))
                        Spacer()
                        Button("Cancel Waiting") { shrinker.cancelWaiting() }
                            .disabled(!shrinker.jobs.contains { $0.phase == .queued })
                        Button("Clear Finished") { shrinker.clearFinished() }
                    }
                    ForEach(shrinker.jobs) { job in jobRow(job) }
                }

                if !records.isEmpty {
                    Text("Results").font(.title3.weight(.semibold)).padding(.top, 6)
                    ForEach(records) { record in recordRow(record) }
                }
            }
            .padding(16)
        }
    }

    private func jobRow(_ job: Shrinker.Job) -> some View {
        HStack(spacing: 12) {
            Thumbnail(asset: job.item.asset, pixels: 120)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 3) {
                Text("\(job.item.filename) · \(Format.bytes(job.item.size))").fontWeight(.medium)
                if job.phase == .encoding {
                    ProgressView(value: job.progress) { Text("Encoding, \(Int(job.progress * 100))%") }
                        .frame(maxWidth: 320)
                } else if let error = job.error {
                    Text(error).foregroundStyle(.red).lineLimit(3)
                } else if let record = job.record {
                    Text("\(record.summary). \(record.kept.map { "Original kept: \($0)" } ?? "Copy saved to Photos")")
                        .foregroundStyle(record.copy == nil ? .secondary : .primary)
                } else {
                    Text(job.phase.label).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(8)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func recordRow(_ record: ShrinkRecord) -> some View {
        let original = library.itemsById[record.original]
        let copy = record.copy.flatMap { library.itemsById[$0] }
        let state =
            record.kept.map { "Original kept: \($0)" }
            ?? (original == nil ? "Original deleted, space freed" : "Copy in Photos, original still here")
        return HStack(spacing: 12) {
            if let shown = original ?? copy {
                Thumbnail(asset: shown.asset, pixels: 120)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name).fontWeight(.medium)
                Text("\(record.summary). \(state)").font(.callout).foregroundStyle(.secondary)
                Text("\(record.from) → \(record.to)").font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            if let copy { Button("Open Copy") { actions.open(copy) } }
        }
    }
}
