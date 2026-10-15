import XCTest
@testable import CellarCore

final class InputTests: XCTestCase {
    var input: InputInterpreter!
    var t = 0.0

    override func setUp() {
        input = InputInterpreter()
        t = 100
    }

    func touch(_ id: Int, _ phase: TouchPhase, _ x: Double, _ y: Double) -> [Gesture] {
        input.handle(TouchSample(id: id, phase: phase, x: x, y: y), time: t)
    }

    func advance(_ seconds: Double) -> [Gesture] {
        var out: [Gesture] = []
        let end = t + seconds
        while t < end {
            t += 1.0 / 60
            out += input.tick(time: t)
        }
        return out
    }

    func testHoldStillWalksAndLiftStops() {
        XCTAssertEqual(touch(1, .began, 200, 400), [])
        XCTAssertEqual(advance(0.1), [], "No walking before the hold delay")
        XCTAssertEqual(advance(0.2), [.walkBegan])
        XCTAssertEqual(touch(1, .ended, 200, 400), [.walkEnded])
    }

    func testDragFirstOnlyTurnsAndNeverWalks() {
        _ = touch(1, .began, 200, 400)
        _ = advance(0.05)
        let g = touch(1, .moved, 230, 402)
        XCTAssertEqual(g, [.turn(points: 30)])
        XCTAssertEqual(advance(1.0), [], "Holding still after a turn must not start walking")
        XCTAssertEqual(touch(1, .moved, 250, 402), [.turn(points: 20)])
        XCTAssertFalse(touch(1, .ended, 250, 402).contains(.walkEnded))
    }

    func testSteeringWhileWalking() {
        _ = touch(1, .began, 200, 400)
        _ = advance(0.3)
        XCTAssertEqual(touch(1, .moved, 190, 400), [.turn(points: -10)])
        XCTAssertTrue(input.isWalking)
    }

    func testVerticalDragDoesNotTurn() {
        _ = touch(1, .began, 200, 400)
        XCTAssertEqual(touch(1, .moved, 202, 460), [])
        XCTAssertEqual(touch(1, .moved, 204, 520), [])
    }

    func testSecondFingerStopsWalkingImmediately() {
        _ = touch(1, .began, 200, 400)
        _ = advance(0.3)
        XCTAssertEqual(touch(2, .began, 260, 400), [.walkEnded])
        _ = touch(2, .ended, 260, 400)
        // The remaining finger never walks.
        XCTAssertEqual(advance(1), [])
        _ = touch(1, .ended, 200, 400)
    }

    func testTwoFingerTap() {
        _ = touch(1, .began, 200, 400)
        _ = touch(2, .began, 260, 400)
        _ = advance(0.1)
        XCTAssertEqual(touch(1, .ended, 200, 400), [.twoFingerTap])
        XCTAssertEqual(touch(2, .ended, 260, 400), [])
    }

    func testTwoFingerSwipes() {
        for (dx, dy, dir) in [(80.0, 0.0, SwipeDirection.right), (-80, 0, .left), (0, 90, .down), (0, -90, .up)] {
            _ = touch(1, .began, 200, 400)
            _ = touch(2, .began, 260, 400)
            _ = advance(0.05)
            _ = touch(1, .moved, 200 + dx, 400 + dy)
            _ = touch(2, .moved, 260 + dx, 400 + dy)
            XCTAssertEqual(touch(1, .ended, 200 + dx, 400 + dy), [.twoFingerSwipe(dir)])
            _ = touch(2, .ended, 260 + dx, 400 + dy)
            _ = advance(0.5)
        }
    }

    func testTwoFingerHoldFiresOnceWhileHeld() {
        _ = touch(1, .began, 200, 400)
        _ = touch(2, .began, 260, 400)
        XCTAssertEqual(advance(1.0), [.twoFingerHold])
        XCTAssertEqual(advance(1.0), [])
        XCTAssertEqual(touch(1, .ended, 200, 400), [], "No tap after a hold")
        _ = touch(2, .ended, 260, 400)
    }

    func testDoubleTap() {
        _ = touch(1, .began, 200, 400)
        _ = advance(0.08)
        XCTAssertEqual(touch(1, .ended, 200, 400), [.tap])
        _ = advance(0.15)
        _ = touch(1, .began, 202, 401)
        _ = advance(0.08)
        XCTAssertEqual(touch(1, .ended, 202, 401), [.tap, .doubleTap])
    }

    func testOneFingerFlick() {
        _ = touch(1, .began, 200, 400)
        _ = advance(0.05)
        _ = touch(1, .moved, 260, 400)
        _ = advance(0.1)
        XCTAssertTrue(touch(1, .ended, 270, 400).contains(.swipe(.right)))
    }

    func testCancelStopsWalking() {
        _ = touch(1, .began, 200, 400)
        _ = advance(0.3)
        XCTAssertEqual(touch(1, .cancelled, 200, 400), [.walkEnded])
    }
}
