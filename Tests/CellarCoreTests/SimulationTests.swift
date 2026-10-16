import XCTest
@testable import CellarCore

final class SimulationTests: XCTestCase {
    func step(_ sim: Simulation, seconds: Double) -> [SimEvent] {
        var events: [SimEvent] = []
        var t = 0.0
        while t < seconds {
            events += sim.update(dt: 1.0 / 60)
            t += 1.0 / 60
        }
        return events
    }

    func testWalkingIntoWallStopsAndBumpsOnce() throws {
        let sim = Simulation(world: try Fixtures.basement())
        // Start (3.6, 1.4) facing north; the north wall is at y = 5.
        sim.setWalking(true)
        let events = step(sim, seconds: 8)
        XCTAssertEqual(sim.position.y, 5 - sim.world.playerRadius, accuracy: 0.01)
        XCTAssertEqual(sim.position.x, 3.6, accuracy: 0.01)
        let bumps = events.filter { if case .wallBump = $0 { return true } else { return false } }
        XCTAssertEqual(bumps.count, 1, "Holding against a wall must not repeat the impact")
        // No footsteps while pressing against the wall: count steps in the last 4 seconds.
        let later = step(sim, seconds: 4)
        XCTAssertFalse(later.contains { if case .footstep = $0 { return true } else { return false } })
    }

    func testBumpRearmsAfterBackingOff() throws {
        let sim = Simulation(world: try Fixtures.basement())
        sim.setWalking(true)
        _ = step(sim, seconds: 5)
        sim.setWalking(false)
        sim.turnAround()
        _ = step(sim, seconds: 1)
        sim.setWalking(true)
        _ = step(sim, seconds: 0.6)
        sim.setWalking(false)
        sim.turnAround()
        _ = step(sim, seconds: 1)
        sim.setWalking(true)
        let events = step(sim, seconds: 2)
        XCTAssertTrue(events.contains { if case .wallBump = $0 { return true } else { return false } })
    }

    func testSlidingAlongWallIsContactNotBump() throws {
        let sim = Simulation(world: try Fixtures.basement())
        sim.teleport(to: Vec2(3, 4.5), headingDegrees: 70) // shallow angle toward north wall, heading east-ish
        sim.setWalking(true)
        let events = step(sim, seconds: 1.5)
        XCTAssertFalse(events.contains { if case .wallBump = $0 { return true } else { return false } })
        XCTAssertTrue(events.contains { if case .wallContactBegan = $0 { return true } else { return false } })
        XCTAssertGreaterThan(sim.position.x, 4.0, "Should keep sliding along the wall")
        XCTAssertTrue(events.contains { if case .wallBrush = $0 { return true } else { return false } })
    }

    func testFootstepCadenceMatchesStride() throws {
        let sim = Simulation(world: try Fixtures.basement())
        sim.teleport(to: Vec2(1, 2.5), headingDegrees: 90) // walk east across the room
        sim.setWalking(true)
        let events = step(sim, seconds: 3)
        let steps = events.filter { if case .footstep(_, _, _, _, false) = $0 { return true } else { return false } }
        // 3 s at 1.15 m/s = 3.45 m; stride 0.68 m, first step early -> about 5 steps.
        XCTAssertTrue((4...6).contains(steps.count), "got \(steps.count)")
        if case .footstep(let surface, _, _, _, _) = steps[0] {
            XCTAssertEqual(surface, .wetConcrete)
        }
    }

    func testThresholdIntoCorridorChangesSurface() throws {
        let sim = Simulation(world: try Fixtures.basement())
        sim.teleport(to: Vec2(4.5, 2.8), headingDegrees: 90)
        sim.setWalking(true)
        let events = step(sim, seconds: 3)
        XCTAssertTrue(events.contains(.threshold(from: 0, to: 1)))
        XCTAssertEqual(sim.world.rooms[sim.room].id, "corridor")
        let woodSteps = events.filter { if case .footstep(.woodBoards, _, _, _, _) = $0 { return true } else { return false } }
        XCTAssertFalse(woodSteps.isEmpty)
    }

    func testStopIsImmediate() throws {
        let sim = Simulation(world: try Fixtures.basement())
        sim.setWalking(true)
        _ = step(sim, seconds: 0.5)
        sim.setWalking(false)
        let p = sim.position
        _ = step(sim, seconds: 2)
        XCTAssertEqual(sim.position, p)
    }

    func testLargeFrameGapDoesNotJump() throws {
        let sim = Simulation(world: try Fixtures.basement())
        sim.setWalking(true)
        let p = sim.position
        _ = sim.update(dt: 30) // e.g. returning from a long stall
        XCTAssertLessThanOrEqual(sim.position.distance(to: p), 0.05 * sim.tuning.walkSpeed + 1e-9)
    }

    func testSwipeTurnsLandOnEightDirections() throws {
        let sim = Simulation(world: try Fixtures.basement())
        XCTAssertEqual(sim.snapTurn(direction: 1), 45)
        _ = step(sim, seconds: 1)
        XCTAssertEqual(sim.headingDegrees, 45, accuracy: 1e-6)
        sim.snapTurn(direction: 1)
        var events = step(sim, seconds: 1)
        XCTAssertEqual(sim.headingDegrees, 90, accuracy: 1e-6)
        XCTAssertTrue(events.contains(.aligned(cardinal: 1)), "Facing along the walls gives a tick")
        // Quick repeated swipes add up exactly.
        sim.snapTurn(direction: -1)
        sim.snapTurn(direction: -1)
        sim.snapTurn(direction: -1)
        _ = step(sim, seconds: 1)
        XCTAssertEqual(sim.headingDegrees, 315, accuracy: 1e-6)
        XCTAssertEqual(sim.turnAround(), 135)
        events = step(sim, seconds: 1.5)
        XCTAssertEqual(sim.headingDegrees, 135, accuracy: 1e-6)
        XCTAssertTrue(events.contains(.pivot), "Turning on the spot shuffles the feet")
        // A slightly-off heading snaps onto the grid.
        sim.turn(byDegrees: 7)
        XCTAssertEqual(sim.snapTurn(direction: 1, step: 90), 180, accuracy: 1e-6)
        _ = step(sim, seconds: 1)
        XCTAssertEqual(sim.headingDegrees, 180, accuracy: 1e-6)
    }

    func testAlignedTickWhenDraggingAcrossNorth() throws {
        let sim = Simulation(world: try Fixtures.basement())
        sim.turn(byDegrees: -10)
        var events = sim.update(dt: 0.016)
        XCTAssertFalse(events.contains { if case .aligned = $0 { return true } else { return false } },
                       "Leaving a cardinal heading is not a crossing")
        sim.turn(byDegrees: 20)
        events = sim.update(dt: 0.016)
        XCTAssertTrue(events.contains(.aligned(cardinal: 0)))
    }

    /// Random walking and turning must never leave the walkable space.
    func testRandomWalkNeverPassesThroughWalls() throws {
        let world = try Fixtures.basement()
        let sim = Simulation(world: world)
        var rng = SoundSynth.RNG(5)
        for frame in 0..<60_000 {
            if frame % 40 == 0 {
                sim.setWalking(rng.unit() < 0.8)
                sim.turn(byDegrees: rng.range(-120, 120))
            }
            _ = sim.update(dt: rng.range(0.005, 0.08))
            let p = sim.position
            XCTAssertTrue(world.rooms.contains { $0.rect.contains(p, inset: -1e-6) }, "Escaped at \(p)")
            XCTAssertGreaterThanOrEqual(world.nearestWallDistance(to: p), world.playerRadius - 1e-3, "Inside wall at \(p)")
            if world.nearestWallDistance(to: p) < world.playerRadius - 1e-3 { return }
        }
        XCTAssertGreaterThan(sim.visitedRooms.count, 1)
    }
}
