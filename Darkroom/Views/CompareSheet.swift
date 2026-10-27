import AVKit
import SwiftUI

/// A copy refused for its quality score next to its original, in one player that switches between the two
/// at the same moment: the easiest way to see what the encoding lost. Then save the copy anyway, or not.
struct CompareSheet: View {
    let record: ShrinkRecord
    let original: Item
    let file: URL
    @Environment(Shrinker.self) private var shrinker
    @Environment(\.dismiss) private var dismiss
    @State private var originalPlayer: AVPlayer?
    @State private var copyPlayer: AVPlayer
    @State private var showCopy = true
    @State private var saving = false
    @State private var error: String?

    init(record: ShrinkRecord, original: Item, file: URL) {
        self.record = record
        self.original = original
        self.file = file
        _copyPlayer = State(initialValue: AVPlayer(url: file))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(record.name): original or copy?").font(.title2.weight(.semibold))
            Text(
                "The copy is \(record.sizes) and scored \(record.vmaf.map { "\($0)" } ?? "?") on the quality check, below \(Int(record.requiredQuality)). Pause on a frame and switch between the two: the difference shows first in fine detail like grass, leaves, hair or water."
            )
            .foregroundStyle(.secondary)
            Picker("Show", selection: $showCopy) {
                Text("Original").tag(false)
                Text("Copy").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)

            ZStack {
                if let player = showCopy ? copyPlayer : originalPlayer {
                    PlayerView(player: player)
                } else {
                    ProgressView("Getting the original from Photos…")
                }
            }
            .frame(minWidth: 720, idealWidth: 960, minHeight: 405, idealHeight: 540)

            if let error { Text(error).foregroundStyle(.red) }

            HStack {
                Button("Discard Copy", role: .destructive) {
                    pause()
                    ShrinkRecords.discardPreview(record)
                    dismiss()
                }
                Spacer()
                Button("Close", role: .cancel) {
                    pause()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : "Save Copy to Photos") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }
        }
        .padding(20)
        .task { originalPlayer = await VideoPreview.player(for: original.asset, deliveryMode: .highQualityFormat) }
        .onChange(of: showCopy) { wasCopy, isCopy in
            let from = wasCopy ? copyPlayer : originalPlayer
            let to = isCopy ? copyPlayer : originalPlayer
            let playing = (from?.rate ?? 0) > 0
            from?.pause()
            if let from, let to { to.seek(to: from.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero) }
            if playing { to?.play() }
        }
    }

    private func pause() {
        originalPlayer?.pause()
        copyPlayer.pause()
    }

    private func save() {
        pause()
        saving = true
        Task {
            do {
                try await shrinker.saveAnyway(record)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                saving = false
            }
        }
    }
}
