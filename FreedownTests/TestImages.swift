import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Small pictures drawn for the tests, so nothing comes from the photo library
enum TestImages {
    /// A grey gradient, dark to light from left to right (or the other way)
    static func gradient(width: Int = 64, height: Int = 48, reversed: Bool = false, brighter: Int = 0) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            for column in 0..<width {
                let x = reversed ? width - 1 - column : column
                pixels[row * width + column] = UInt8(min(255, x * 255 / (width - 1) / 2 + row + brighter))
            }
        }
        let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        return context.makeImage()!
    }

    /// Soft shapes with grain, like a photo: smooth enough to compress, detailed enough to be worth it
    static func noise(width: Int, height: Int) -> CGImage {
        var generator = SystemRandomNumberGenerator()
        var pixels = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            for column in 0..<width {
                let shape = 128 + 60 * sin(Double(column) / 40) * cos(Double(row) / 30)
                pixels[row * width + column] = UInt8(max(0, min(255, shape + Double(Int.random(in: -12...12, using: &generator)))))
            }
        }
        let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        return context.makeImage()!
    }

    /// Writes an image as a JPEG file
    static func jpeg(_ image: CGImage, quality: Double = 0.9) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appending(path: "freedown-test-\(UUID().uuidString).jpg")
        let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return file
    }
}
