import XCTest
@testable import CellarCore

final class WorldTests: XCTestCase {
    func testBasementLoadsAndValidates() throws {
        let world = try Fixtures.basement()
        XCTAssertEqual(world.rooms.count, 6)
        XCTAssertEqual(world.doorways.count, 5)
        XCTAssertEqual(world.walls.count, 32, "Matches tools/validate_world.py")
        XCTAssertEqual(world.rooms[world.startRoom].id, "pumpRoom")
        XCTAssertEqual(world.rooms[world.exitRoom].id, "stairwell")
    }

    func testWallsHaveGapsAtEveryDoorway() throws {
        let world = try Fixtures.basement()
        for d in world.doorways {
            // The doorway centre is not on any wall, and a line straight through it is clear.
            XCTAssertGreaterThan(world.nearestWallDistance(to: d.center), 0.3, d.id)
            let e = (d.segment.b - d.segment.a).normalized
            let n = Vec2(-e.y, e.x)
            XCTAssertTrue(world.hasLineOfSight(d.center + n * 0.5, d.center - n * 0.5), d.id)
        }
    }

    func testRoomsAreSealedExceptAtDoorways() throws {
        let world = try Fixtures.basement()
        // Pump room to vent room straight line crosses walls.
        XCTAssertFalse(world.hasLineOfSight(Vec2(3, 3), Vec2(10, 6)))
        // Junction to storage directly (not through the opening) crosses a wall.
        XCTAssertFalse(world.hasLineOfSight(Vec2(18.5, 1), Vec2(18.5, -1)))
        XCTAssertTrue(world.hasLineOfSight(Vec2(20.5, 1), Vec2(20.5, -1)))
    }

    func testEveryRoomRoutable() throws {
        let world = try Fixtures.basement()
        for i in world.rooms.indices {
            XCTAssertNotNil(world.doorwayRoute(from: world.startRoom, to: i), world.rooms[i].id)
        }
        XCTAssertEqual(world.doorwayRoute(from: world.startRoom, to: world.exitRoom)?.count, 3)
    }

    func testValidationRejectsBrokenWorlds() throws {
        var def = try Fixtures.basementDefinition()
        def.doorways[0].b = Vec2(6, 2.6) // 0.4 m: too narrow
        XCTAssertThrowsError(try World(def))

        def = try Fixtures.basementDefinition()
        def.rooms[1].rect = Rect(x0: 5, y0: 2, x1: 18, y1: 3.6) // overlaps the pump room
        XCTAssertThrowsError(try World(def))

        def = try Fixtures.basementDefinition()
        def.doorways.removeAll { $0.id == "junction-stairs" } // exit cut off
        XCTAssertThrowsError(try World(def))

        def = try Fixtures.basementDefinition()
        def.doorways[1].a = Vec2(9.5, 3.7) // off the shared edge
        def.doorways[1].b = Vec2(10.7, 3.7)
        XCTAssertThrowsError(try World(def))
    }

    func testSurfaceZones() throws {
        let world = try Fixtures.basement()
        let stairs = world.rooms.firstIndex { $0.id == "stairwell" }!
        XCTAssertEqual(world.surface(at: Vec2(20.5, 6.5), room: stairs).surface, .dryConcrete)
        XCTAssertTrue(world.surface(at: Vec2(20.5, 9), room: stairs).stairs)
        XCTAssertEqual(world.surface(at: Vec2(20.5, 11.5), room: stairs).surface, .outside)
    }

    func testListenerSpace() {
        // Facing north, a point to the east is on the right.
        var lp = ListenerPoint(world: Vec2(5, 0), listener: .zero, heading: 0)
        XCTAssertEqual(lp.right, 5, accuracy: 1e-9)
        XCTAssertEqual(lp.forward, 0, accuracy: 1e-9)
        // Facing east, the same point is straight ahead.
        lp = ListenerPoint(world: Vec2(5, 0), listener: .zero, heading: Double.pi / 2)
        XCTAssertEqual(lp.forward, 5, accuracy: 1e-9)
        XCTAssertEqual(lp.right, 0, accuracy: 1e-9)
        // Facing south, it's on the left.
        lp = ListenerPoint(world: Vec2(5, 0), listener: .zero, heading: Double.pi)
        XCTAssertEqual(lp.right, -5, accuracy: 1e-9)
        XCTAssertEqual(Orientation.relativeWord(bearing: lp.bearing), "on your left")
    }

    func testCompassWords() {
        XCTAssertEqual(Orientation.compassWord(headingDegrees: 0), "north")
        XCTAssertEqual(Orientation.compassWord(headingDegrees: 359), "north")
        XCTAssertEqual(Orientation.compassWord(headingDegrees: 90), "east")
        XCTAssertEqual(Orientation.compassWord(headingDegrees: -90), "west")
        XCTAssertEqual(Orientation.compassWord(headingDegrees: 225), "south-west")
    }
}
