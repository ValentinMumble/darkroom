import Foundation
import Testing

@testable import Freedpics

struct PairingTests {
    /// Only a Live Photo's still carries the id that pairs it with its motion
    @Test func aPlainJPEGHasNoPairingID() throws {
        let file = try TestImages.jpeg(TestImages.gradient())
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(Replacer.stillPairingID(file) == nil)
    }
}
