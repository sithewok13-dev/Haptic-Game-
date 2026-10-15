import XCTest
@testable import CellarCore

final class PropagationTests: XCTestCase {
    var world: World!

    override func setUpWithError() throws {
        world = try Fixtures.basement()
    }

    func source(_ id: String) -> SoundSource { world.sources.first { $0.id == id }! }
    func room(_ id: String) -> Int { world.rooms.firstIndex { $0.id == id }! }

    func testSameRoomIsDirect() {
        let drip = source("drip")
        let p = Propagation.path(in: world, listener: Vec2(3.6, 1.4), listenerRoom: room("pumpRoom"),
                                 source: drip.position, sourceRoom: drip.room)!
        XCTAssertEqual(p.apparentPosition, drip.position)
        XCTAssertEqual(p.transmission, 1)
        XCTAssertEqual(p.openings, 0)
    }

    func testHiddenSourceIsHeardThroughTheOpening() {
        // Standing in the corridor east of the pump room, the drip must come from the
        // doorway to the west, not straight through the wall toward the north-west.
        let drip = source("drip")
        let listener = Vec2(9, 2.8)
        let p = Propagation.path(in: world, listener: listener, listenerRoom: room("corridor"),
                                 source: drip.position, sourceRoom: drip.room)!
        XCTAssertEqual(p.openings, 1)
        let dir = (p.apparentPosition - listener).normalized
        let toDoor = (Vec2(6, 2.8) - listener).normalized
        XCTAssertGreaterThan(dir.dot(toDoor), 0.98, "Apparent direction should point at the opening")
        // Distance equals the walking path, so it is quieter than straight-line distance would suggest.
        XCTAssertGreaterThan(p.length, listener.distance(to: drip.position))
        // The first leg of the path is walkable (no wall crossed).
        XCTAssertTrue(world.hasLineOfSight(listener, p.points[1]))
    }

    func testCornerMuffles() {
        let fan = source("fan")
        // In the corridor beside the vent room opening, but the fan is round the corner.
        let side = Propagation.path(in: world, listener: Vec2(7, 2.4), listenerRoom: room("corridor"),
                                    source: fan.position, sourceRoom: fan.room)!
        // Directly below the opening, looking up into the room.
        let below = Propagation.path(in: world, listener: Vec2(10.1, 2.4), listenerRoom: room("corridor"),
                                     source: Vec2(10.1, 7), sourceRoom: fan.room)!
        XCTAssertGreaterThan(side.muffle, below.muffle)
        XCTAssertLessThan(side.transmission, below.transmission)
    }

    func testExitIsFaintFromStartButClearNearStairs() {
        let draft = source("draft")
        let scene = AudioScene(world: world)
        let fromStart = scene.target(for: draft, listener: Vec2(3.6, 1.4), room: room("pumpRoom")).gain
        let fromJunction = scene.target(for: draft, listener: Vec2(20.5, 3), room: room("junction")).gain
        let fromStairs = scene.target(for: draft, listener: Vec2(20.5, 7), room: room("stairwell")).gain
        XCTAssertLessThan(fromStart, fromJunction * 0.3, "Exit must not be loud through every wall")
        XCTAssertLessThan(fromJunction, fromStairs)
        XCTAssertGreaterThan(fromJunction, 0.05, "But it should be audible at the junction")
    }

    /// Walking through a doorway must not make any source jump in direction or level.
    func testContinuityAcrossThresholds() {
        let crossings: [(Vec2, Vec2)] = [
            (Vec2(4.5, 2.8), Vec2(7.5, 2.8)),     // pump room -> corridor
            (Vec2(10.1, 2.4), Vec2(10.1, 5.0)),   // corridor -> vent room
            (Vec2(16.5, 2.8), Vec2(19.5, 2.8)),   // corridor -> junction
            (Vec2(20.5, 4.5), Vec2(20.5, 7.5)),   // junction -> stairwell
            (Vec2(20.5, 1.5), Vec2(20.5, -1.5)),  // junction -> storage
        ]
        for (a, b) in crossings {
            for s in world.sources {
                var prev: (dir: Vec2, gain: Double)?
                var currentRoom = world.room(at: a)!
                let steps = 300
                for i in 0...steps {
                    let p = a + (b - a) * (Double(i) / Double(steps))
                    currentRoom = world.room(at: p, current: currentRoom)!
                    let scene = AudioScene(world: world)
                    let t = scene.target(for: s, listener: p, room: currentRoom)
                    let dir = (t.position - p).normalized
                    if let pr = prev {
                        if t.gain > 0.02 {
                            XCTAssertLessThan(abs(t.gain - pr.gain), 0.03,
                                              "\(s.id) gain jumps at \(p) crossing \(a)->\(b)")
                            XCTAssertGreaterThan(dir.dot(pr.dir), 0.9,
                                                 "\(s.id) direction jumps at \(p) crossing \(a)->\(b)")
                        }
                    }
                    prev = (dir, t.gain)
                }
            }
        }
    }

    func testLandmarkStaysFixedWhenTurning() {
        let scene = AudioScene(world: world)
        let p = Vec2(3.6, 1.4)
        let drip = world.sources.firstIndex { $0.id == "drip" }!
        let north = scene.update(listener: p, heading: 0, room: 0, dt: 1, wallSense: false).sources[drip].position
        let west = scene.update(listener: p, heading: -Double.pi / 2, room: 0, dt: 1, wallSense: false).sources[drip].position
        XCTAssertLessThan(north.right, 0, "Drip is ahead-left when facing north")
        XCTAssertGreaterThan(west.right, 0, "and ahead-right when facing west")
        XCTAssertEqual(north.distance, west.distance, accuracy: 1e-9)
    }

    func testWallSenseFindsOpenings() {
        let scene = AudioScene(world: world)
        let corridor = room("corridor")
        // Walking east along the corridor's north side: wall on the left...
        var probes = scene.update(listener: Vec2(8.5, 3.3), heading: Double.pi / 2, room: corridor,
                                  dt: 10, wallSense: true).probes
        XCTAssertGreaterThan(probes[0].gain, 0.1, "wall close on the left")
        // ...which disappears at the vent room opening.
        scene.reset()
        probes = scene.update(listener: Vec2(10.1, 3.3), heading: Double.pi / 2, room: corridor,
                              dt: 10, wallSense: true).probes
        XCTAssertLessThan(probes[0].gain, 0.02, "opening on the left is silent")
        XCTAssertGreaterThan(probes[2].gain, 0.0, "far corridor wall still on the right")
        // Disabled means silent.
        scene.reset()
        probes = scene.update(listener: Vec2(8.5, 3.3), heading: Double.pi / 2, room: corridor,
                              dt: 10, wallSense: false).probes
        XCTAssertTrue(probes.allSatisfy { $0.gain < 1e-9 })
    }
}
