import Foundation
import ImageIO
import Testing

@testable import Freedown

struct StillsTests {
    @Test func aPictureScoresAHundredAgainstItself() {
        let image = TestImages.gradient(width: 256, height: 192)
        #expect(Stills.score(image, image) > 99.99)
    }

    @Test func aDifferentPictureScoresLow() {
        let image = TestImages.gradient(width: 256, height: 192)
        let mirrored = TestImages.gradient(width: 256, height: 192, reversed: true)
        #expect(Stills.score(image, mirrored) < Stills.minScore)
    }

    /// A finely detailed JPEG saved at high quality, the kind a camera writes, becomes a smaller HEIC that looks the same
    @Test func aDetailedJPEGBecomesASmallerHEICThatLooksTheSame() throws {
        let jpeg = try TestImages.jpeg(TestImages.noise(width: 1200, height: 900), quality: 0.98)
        let heic = jpeg.deletingPathExtension().appendingPathExtension("heic")
        defer { try? FileManager.default.removeItem(at: jpeg) }
        defer { try? FileManager.default.removeItem(at: heic) }
        let conversion = try Stills.heic(from: jpeg, to: heic)
        #expect(conversion.score >= Stills.minScore)
        let source = try #require(CGImageSourceCreateWithURL(heic as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.heic")
    }

    /// A JPEG compressed hard has nothing left for HEIC to save: it is refused, and the refusal is remembered
    @Test func aHeavilyCompressedJPEGIsRefused() throws {
        let jpeg = try TestImages.jpeg(TestImages.noise(width: 1200, height: 900), quality: 0.3)
        let heic = jpeg.deletingPathExtension().appendingPathExtension("heic")
        defer { try? FileManager.default.removeItem(at: jpeg) }
        defer { try? FileManager.default.removeItem(at: heic) }
        #expect(throws: Stills.Refusal.self) { try Stills.heic(from: jpeg, to: heic) }
    }

    @Test func theExpectedSavingFollowsTheBitsPerPixel() {
        // A 12-megapixel photo of 1.5 MB is 1 bit per pixel: phones compress that hard
        let twelveMegapixels = 4000 * 3000
        #expect(Stills.bitsPerPixel(size: 1_500_000, pixels: twelveMegapixels) == 1)
        #expect(Stills.bitsPerPixel(size: 1_500_000, pixels: 0) == 0)
        #expect(Stills.expectedSaving(bitsPerPixel: 1) == 0)
        #expect(Stills.expectedSaving(bitsPerPixel: 1.5) == 0.2)
        #expect(Stills.expectedSaving(bitsPerPixel: 3.9) == 0.2)
        #expect(Stills.expectedSaving(bitsPerPixel: 4) == 0.55)
    }

    @Test func aDrawnPictureHasNoHDRLayer() throws {
        let file = try TestImages.jpeg(TestImages.gradient())
        defer { try? FileManager.default.removeItem(at: file) }
        let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
        #expect(!Stills.hasGainMap(source))
    }
}
