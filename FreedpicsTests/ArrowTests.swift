import AppKit
import Testing

@testable import Freedpics

struct ArrowTests {
    @Test func theArrowKeysGiveTheirDirection() {
        #expect(Arrow.Direction(.leftArrow) == .left)
        #expect(Arrow.Direction(.rightArrow) == .right)
        #expect(Arrow.Direction(.upArrow) == .up)
        #expect(Arrow.Direction(.downArrow) == .down)
    }

    @Test func otherKeysGiveNone() {
        #expect(Arrow.Direction(.carriageReturn) == nil)
        #expect(Arrow.Direction(nil) == nil)
    }

    @Test func eachPressIsNew() {
        #expect(Arrow(direction: .left) != Arrow(direction: .left))
    }
}
