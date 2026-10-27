import SwiftUI

struct ShrinkRequest: Identifiable {
    let id = UUID()
    let items: [Item]
}

struct ShrinkSheet: View {
    let items: [Item]
    let onStart: ([Item], ShrinkPreset) -> Void
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var preset = ShrinkPreset.high

    var body: some View {
        let eligible = items.filter { library.shrinkSkip($0) == nil }
        let skipped = items.compactMap { item in library.shrinkSkip(item).map { "\(item.filename): \($0)" } }
        let minutes = eligible.reduce(0) { $0 + $1.duration } / 60
        VStack(alignment: .leading, spacing: 14) {
            Text("Shrink \(Format.count(eligible.count, "video")) (\(Format.bytes(eligible.reduce(0) { $0 + $1.size })))")
                .font(.title2.weight(.semibold))
            Text(
                "Each video is downloaded from iCloud if needed, re-encoded to HEVC with ffmpeg, then scored for quality (VMAF, 100 = identical). The copy goes into Photos with the same date, place, favorite and albums, only when it is at least 20% smaller and good enough. Count about 2 to 3 times the length of the videos: here roughly \(max(1, Int(minutes * 2.5))) minutes."
            )
            Text(
                "Nothing is deleted: the originals stay until you delete them from Shrinking. Until then the copies take extra iCloud space\(library.storage?.free.map { " (\(Format.bytes($0)) free now)" } ?? "")."
            )
            .foregroundStyle(.secondary)
            if FFmpeg.ffmpeg == nil {
                Label("Needs ffmpeg. Install it with brew install ffmpeg, then try again.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Picker("Quality", selection: $preset) {
                ForEach(ShrinkPreset.allCases) { option in
                    Text("\(option.label): \(option.detail)").tag(option)
                }
            }
            .pickerStyle(.radioGroup)
            if !skipped.isEmpty {
                Text("Left out: " + skipped.joined(separator: "; ")).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start") {
                    onStart(eligible, preset)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(eligible.isEmpty || FFmpeg.ffmpeg == nil)
            }
        }
        .padding(20)
        .frame(width: 540)
    }
}
