import Foundation

/// Homebrew's ffmpeg. Apple's own HEVC encoder made the library's iPhone videos bigger at the same quality;
/// libx265 is what actually shrinks them, and libvmaf checks the result.
enum FFmpeg {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Probe {
        let duration: Double
        let frames: Int
        /// "hevc 1080x1920 yuv420p10le HDR"
        let summary: String
    }

    static let ffmpeg: URL? = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        .map { URL(filePath: $0) }
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }

    static var ffprobe: URL? { ffmpeg?.deletingLastPathComponent().appending(path: "ffprobe") }

    static func probe(_ file: URL) throws -> Probe {
        struct Output: Decodable {
            struct Stream: Decodable {
                let codec_name: String
                let width: Int
                let height: Int
                let pix_fmt: String?
                let color_transfer: String?
                let nb_frames: String?
            }
            struct Format: Decodable { let duration: String }
            let streams: [Stream]
            let format: Format
        }
        let arguments = [
            "-v", "error", "-of", "json", "-select_streams", "v:0", "-show_entries",
            "format=duration:stream=codec_name,pix_fmt,color_transfer,width,height,nb_frames", file.path,
        ]
        let (output, _) = try run(ffprobe, arguments)
        let probe = try JSONDecoder().decode(Output.self, from: Data(output.utf8))
        guard let video = probe.streams.first else { throw Failure(message: "no video stream in \(file.lastPathComponent)") }
        let hdr = ["arib-std-b67", "smpte2084"].contains(video.color_transfer ?? "")
        return Probe(
            duration: Double(probe.format.duration) ?? 0,
            frames: Int(video.nb_frames ?? "") ?? 0,
            summary: "\(video.codec_name) \(video.width)x\(video.height) \(video.pix_fmt ?? "") \(hdr ? "HDR" : "SDR")")
    }

    /// Re-encodes to HEVC, keeping the audio and the file's own metadata (date with its time zone, place, camera).
    static func encode(_ source: URL, to output: URL, crf: Int, duration: Double, progress: @escaping (Double) -> Void)
        throws
    {
        let arguments = [
            "-hide_banner", "-loglevel", "error", "-nostats", "-progress", "pipe:1", "-y", "-i", source.path,
            "-map", "0:v:0", "-map", "0:a:0?",
            // Keep every frame at its original time: iPhone videos have an uneven frame rate
            "-fps_mode", "passthrough",
            "-c:v", "libx265", "-preset", "medium", "-crf", String(crf), "-x265-params", "log-level=error",
            "-tag:v", "hvc1", "-c:a", "copy",
            "-map_metadata", "0", "-movflags", "+faststart+use_metadata_tags",
            output.path,
        ]
        try run(ffmpeg, arguments) { line in
            if line.hasPrefix("out_time_us="), let microseconds = Double(line.dropFirst("out_time_us=".count)),
                duration > 0
            {
                progress(min(1, microseconds / 1e6 / duration))
            }
        }
    }

    /// How close the copy looks to the original, 0 to 100 (93 or more: hard to tell apart), on every 5th frame.
    /// Frames are paired by index: iPhone videos have an uneven frame rate, and pairing them by timestamp
    /// compares the wrong frames and scores a perfect copy around 45.
    static func vmaf(_ copy: URL, against original: URL) throws -> Double {
        let graph =
            "[0:v]settb=1/1000,setpts=N*16[copy];[1:v]settb=1/1000,setpts=N*16[original];"
            + "[copy][original]libvmaf=n_threads=8:n_subsample=5"
        let (_, errors) = try run(
            ffmpeg, ["-hide_banner", "-i", copy.path, "-i", original.path, "-lavfi", graph, "-f", "null", "-"])
        guard let match = errors.firstMatch(of: /VMAF score: ([\d.]+)/), let score = Double(match.1) else {
            throw Failure(message: "no VMAF score: \(errors.suffix(300))")
        }
        return (score * 10).rounded() / 10
    }

    /// Runs a tool to the end; `onLine` gets each line of its standard output as it comes.
    @discardableResult
    static func run(_ tool: URL?, _ arguments: [String], onLine: ((String) -> Void)? = nil) throws -> (String, String) {
        guard let tool else { throw Failure(message: "ffmpeg is not installed: run brew install ffmpeg") }
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()

        // Standard error is read on another thread, so neither pipe fills up and stalls the tool
        let errorData = Locked(Data())
        let reading = DispatchGroup()
        reading.enter()
        DispatchQueue.global().async {
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            errorData.update { $0 = data }
            reading.leave()
        }
        var outputData = Data()
        var pending = ""
        while case let chunk = output.fileHandleForReading.availableData, !chunk.isEmpty {
            outputData.append(chunk)
            guard let onLine else { continue }
            pending += String(decoding: chunk, as: UTF8.self)
            while let newline = pending.firstIndex(of: "\n") {
                onLine(String(pending[..<newline]))
                pending.removeSubrange(...newline)
            }
        }
        process.waitUntilExit()
        reading.wait()
        let errorText = String(decoding: errorData.value, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw Failure(message: "\(tool.lastPathComponent) failed: \(errorText.suffix(400))")
        }
        return (String(decoding: outputData, as: UTF8.self), errorText)
    }
}
