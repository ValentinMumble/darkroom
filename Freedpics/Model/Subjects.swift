import Photos
import Vision

/// Whether a photo shows someone: a person (a body or a face), a cat or a dog. Vision runs on this Mac, on a
/// small render of the photo as it looks now. A Live Photo without anyone in it is usually a landscape, food
/// or a thing, where the motion adds little.
enum Subjects {
    /// nil when Photos gave no image or Vision failed: such a photo is not suggested
    nonisolated static func living(_ asset: PHAsset) -> Bool? {
        // Bigger than the similar shots' render: people far away are small
        guard let image = Similar.smallImage(asset, pixels: 640) else { return nil }
        let bodies = VNDetectHumanRectanglesRequest()
        bodies.upperBodyOnly = false
        let faces = VNDetectFaceRectanglesRequest()
        let animals = VNRecognizeAnimalsRequest()
        guard (try? VNImageRequestHandler(cgImage: image).perform([bodies, faces, animals])) != nil else { return nil }
        let threshold: VNConfidence = 0.5
        return (bodies.results ?? []).contains { $0.confidence > threshold }
            || (faces.results ?? []).contains { $0.confidence > threshold }
            || (animals.results ?? []).contains { $0.confidence > threshold }
    }
}
