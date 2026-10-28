import Testing

@testable import Freedpics

/// What replacing an item frees: everything stored for it, minus the files the new item keeps
struct SavingArithmeticTests {
    @Test func removeMotionKeepsOnlyTheStill() {
        // IMG_1332: a 4.9 MB still with 8.2 MB of motion
        #expect(Replacement.saving(size: 13_100, original: 4_900, edited: nil, keptMotion: 0) == 8_200)
    }

    @Test func keepEditedVersionKeepsTheEditedStill() {
        #expect(Replacement.saving(size: 10_000, original: 4_000, edited: 5_000, keptMotion: 0) == 5_000)
    }

    @Test func aLivePhotoKeptLiveKeepsItsMotion() {
        #expect(Replacement.saving(size: 20_000, original: 4_000, edited: 5_000, keptMotion: 6_000) == 9_000)
    }

    @Test func neverBelowZero() {
        #expect(Replacement.saving(size: 1_000, original: 2_000, edited: nil, keptMotion: 0) == 0)
    }
}
