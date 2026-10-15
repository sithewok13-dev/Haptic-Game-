import XCTest
@testable import CellarCore

final class SessionTests: XCTestCase {
    func explored() throws -> GameSession {
        var s = GameSettings()
        s.practiceDone = true
        return GameSession(world: try Fixtures.basement(), settings: s)
    }

    func testPracticeProgression() throws {
        let session = GameSession(world: try Fixtures.basement())
        var clock = 0.0
        XCTAssertEqual(session.begin().spoken, [Script.intro])
        XCTAssertEqual(session.phase, .practice(.walk))

        _ = session.handle(.walkBegan)
        var cues = simulate(session, seconds: 1.5, clock: &clock)
        XCTAssertEqual(session.phase, .practice(.stop))
        XCTAssertTrue(cues.spoken.contains(Script.practiceStop))

        _ = session.handle(.walkEnded)
        cues = simulate(session, seconds: 0.2, clock: &clock)
        XCTAssertEqual(session.phase, .practice(.turnToSound))

        // Turn left until the drip is ahead (it starts about 42 degrees left of north).
        let drip = session.practiceSource!.position
        for _ in 0..<200 where session.phase == .practice(.turnToSound) {
            _ = session.handle(.turn(points: -5))
            cues = simulate(session, seconds: 1.0 / 60, clock: &clock)
        }
        XCTAssertEqual(session.phase, .practice(.approach))
        let lp = ListenerPoint(world: drip, listener: session.sim.position, heading: session.sim.heading)
        XCTAssertLessThan(abs(Heading.degrees(lp.bearing)), 20)

        _ = session.handle(.walkBegan)
        cues = simulate(session, seconds: 6, clock: &clock)
        XCTAssertEqual(session.phase, .exploring)
        XCTAssertTrue(cues.spoken.contains(Script.practiceDone))
        XCTAssertTrue(session.settings.practiceDone)
    }

    func testPauseFreezesAndResumeDoesNotJump() throws {
        let session = try explored()
        var clock = 0.0
        _ = session.begin()
        _ = session.handle(.walkBegan)
        simulate(session, seconds: 0.5, clock: &clock)
        let cues = session.handle(.twoFingerHold)
        XCTAssertEqual(session.phase, .paused)
        XCTAssertTrue(cues.contains(.worldAudio(active: false)))
        XCTAssertFalse(session.sim.isWalking, "Pausing stops movement")
        let p = session.sim.position
        simulate(session, seconds: 5, clock: &clock)
        _ = session.update(dt: 120, now: clock + 120) // app was suspended for two minutes
        XCTAssertEqual(session.sim.position, p)
        _ = session.handle(.twoFingerHold)
        XCTAssertEqual(session.phase, .exploring)
        _ = session.update(dt: 3, now: clock + 123)
        XCTAssertEqual(session.sim.position, p, "Not walking after resume, so no movement at all")
    }

    func testExternalPauseReasons() throws {
        let session = try explored()
        _ = session.begin()
        _ = session.handle(.walkBegan)
        let cues = session.pause(.headphonesRemoved)
        XCTAssertFalse(session.sim.isWalking)
        XCTAssertTrue(cues.spoken.first!.hasPrefix("Headphones disconnected"))
        XCTAssertEqual(session.pauseReason, .headphonesRemoved)
        XCTAssertEqual(session.pausedReminder().spoken.count, 1)
    }

    func testPauseMenuNavigationAndSettings() throws {
        let session = try explored()
        _ = session.begin()
        _ = session.pause(.player)
        XCTAssertEqual(session.currentMenuItem, .resume)
        var cues = session.handle(.swipe(.right))
        XCTAssertEqual(cues.spoken, ["Hear the controls"])
        _ = session.handle(.swipe(.right))
        XCTAssertEqual(session.currentMenuItem, .haptics)
        cues = session.handle(.doubleTap)
        XCTAssertFalse(session.settings.haptics)
        XCTAssertTrue(cues.contains(.settingsChanged(session.settings)))
        XCTAssertEqual(cues.spoken, ["Vibration: off"])
        _ = session.handle(.swipe(.left))
        _ = session.handle(.swipe(.left))
        XCTAssertEqual(session.currentMenuItem, .resume)
        _ = session.handle(.swipe(.left))
        XCTAssertEqual(session.currentMenuItem, .developerMap, "Menu wraps around")
        XCTAssertFalse(session.menuItems.contains(.skipPractice), "Skip only offered during practice")
    }

    func testRestartNeedsConfirmation() throws {
        let session = try explored()
        var clock = 0.0
        _ = session.begin()
        session.sim.teleport(to: Vec2(12, 2.8), headingDegrees: 90)
        _ = session.pause(.player)
        while session.currentMenuItem != .restart { _ = session.handle(.swipe(.right)) }
        var cues = session.handle(.doubleTap)
        XCTAssertEqual(session.phase, .paused)
        XCTAssertTrue(cues.spoken.first!.contains("again"))
        simulate(session, seconds: 1, clock: &clock)
        cues = session.handle(.doubleTap)
        XCTAssertTrue(cues.contains(.restarted))
        XCTAssertEqual(session.phase, .exploring)
        XCTAssertEqual(session.sim.position, session.sim.world.definition.start.position)
    }

    func testSkipPractice() throws {
        let session = GameSession(world: try Fixtures.basement())
        _ = session.begin()
        _ = session.pause(.player)
        XCTAssertTrue(session.menuItems.contains(.skipPractice))
        while session.currentMenuItem != .skipPractice { _ = session.handle(.swipe(.right)) }
        _ = session.handle(.doubleTap)
        XCTAssertEqual(session.phase, .exploring)
        XCTAssertTrue(session.settings.practiceDone)
    }

    func testOrientationAidDescribesWithoutRevealingRoute() throws {
        let session = try explored()
        _ = session.begin()
        let text = session.handle(.twoFingerTap).spoken.first!
        XCTAssertTrue(text.contains("Wet concrete"))
        XCTAssertTrue(text.contains("Facing north"))
        XCTAssertTrue(text.contains("opening ahead to the right"), text)
        XCTAssertTrue(text.contains("Dripping water, ahead to the left"), text)
        XCTAssertFalse(text.lowercased().contains("exit"))
        XCTAssertFalse(text.lowercased().contains("corridor"))
    }

    func testRevisitIsRecognised() throws {
        let session = try explored()
        let sim = session.sim
        sim.teleport(to: Vec2(5, 2.8), headingDegrees: 90)
        sim.setWalking(true)
        for _ in 0..<120 { _ = sim.update(dt: 1.0 / 60) }   // into the corridor
        sim.setWalking(false)
        sim.turnAround()
        for _ in 0..<60 { _ = sim.update(dt: 1.0 / 60) }
        sim.setWalking(true)
        for _ in 0..<120 { _ = sim.update(dt: 1.0 / 60) }   // back into the pump room
        XCTAssertEqual(sim.world.rooms[sim.room].id, "pumpRoom")
        XCTAssertTrue(sim.currentRoomWasVisitedBefore)
        XCTAssertTrue(Orientation.describe(sim: sim).hasPrefix("You've been here before."))
    }

    /// Full playthrough using only player gestures: visits every side room
    /// (including both wrong turns), then reaches the exit.
    func testAutopilotTourReachesExit() throws {
        let session = try explored()
        var clock = 0.0
        _ = session.begin()
        let pilot = Autopilot(session: session, tour: ["ventRoom", "storage"])
        var all: [Cue] = []
        var seconds = 0.0
        while session.phase != .completed && seconds < 240 {
            all += simulate(session, seconds: 1.0 / 60, clock: &clock) { dt in pilot.step(dt: dt) }
            seconds += 1.0 / 60
        }
        XCTAssertEqual(session.phase, .completed, "Stuck at \(session.sim.position) after \(seconds)s")
        XCTAssertEqual(session.sim.visitedRooms.count, 6)
        XCTAssertTrue(all.contains(.completion))
        let thresholds = all.simEvents.filter { if case .threshold = $0 { return true } else { return false } }
        XCTAssertGreaterThanOrEqual(thresholds.count, 7)
        // Completion message arrives after the sound, then double-tap replays.
        all = simulate(session, seconds: 5, clock: &clock)
        XCTAssertTrue(all.spoken.contains(Script.completion))
        let replay = session.handle(.doubleTap)
        XCTAssertTrue(replay.contains(.restarted))
        XCTAssertEqual(session.phase, .exploring)
        XCTAssertFalse(session.sim.reachedExit)
    }

    /// Raw touches all the way to movement: hold walks, lift stops, drag-only turns in place.
    func testRawTouchesDriveMovement() throws {
        let session = try explored()
        _ = session.begin()
        var now = 10.0
        func frames(_ n: Int) { for _ in 0..<n { now += 1.0 / 60; _ = session.update(dt: 1.0 / 60, now: now) } }
        let start = session.sim.position
        _ = session.handleTouches([TouchSample(id: 1, phase: .began, x: 200, y: 400)], time: now)
        frames(60)
        XCTAssertTrue(session.sim.isWalking)
        XCTAssertGreaterThan(session.sim.position.y - start.y, 0.8, "Walked north about 0.95 m")
        _ = session.handleTouches([TouchSample(id: 1, phase: .ended, x: 200, y: 400)], time: now)
        let stopped = session.sim.position
        frames(30)
        XCTAssertEqual(session.sim.position, stopped, "Lifting stops at once")

        // Drag sideways from a fresh touch: turns about 90 degrees right, no walking.
        _ = session.handleTouches([TouchSample(id: 2, phase: .began, x: 100, y: 400)], time: now)
        frames(3)
        for i in 1...15 {
            _ = session.handleTouches([TouchSample(id: 2, phase: .moved, x: 100 + Double(i) * 15, y: 400)], time: now)
            frames(1)
        }
        frames(60)
        _ = session.handleTouches([TouchSample(id: 2, phase: .ended, x: 325, y: 400)], time: now)
        XCTAssertEqual(session.sim.headingDegrees, 90, accuracy: 0.5)
        XCTAssertEqual(session.sim.position, stopped, "Turning on the spot does not move the player")
    }

    func testSoundsRender() {
        for id in SoundSynth.allIDs {
            let x = SoundSynth.render(id)
            XCTAssertGreaterThan(x.count, 100, id)
            XCTAssertTrue(x.allSatisfy { $0.isFinite && abs($0) <= 1 }, id)
            XCTAssertGreaterThan(x.map { abs($0) }.max()!, 0.1, "\(id) is silent")
        }
    }
}
