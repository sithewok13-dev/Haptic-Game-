import Foundation

/// Drives a session through the same gestures a player would use, following
/// openings room by room. Used by tests and by the in-app self-test
/// (launch argument `-selftest`) to prove the world is traversable end to end.
public final class Autopilot {
    public private(set) var waypoints: [Vec2] = []
    public private(set) var index = 0
    private let session: GameSession
    private var walking = false

    /// Visits each room in `tour` in order, then the exit.
    public init(session: GameSession, tour: [String] = []) {
        self.session = session
        let world = session.sim.world
        var room = session.sim.room
        var targets = tour.compactMap { id in world.rooms.firstIndex { $0.id == id } }
        targets.append(world.exitRoom)
        for target in targets {
            guard let route = world.doorwayRoute(from: room, to: target) else { continue }
            for di in route {
                let d = world.doorways[di]
                let e = (d.segment.b - d.segment.a).normalized
                var n = Vec2(-e.y, e.x)
                if (world.rooms[room].rect.center - d.center).dot(n) < 0 { n = -n }
                waypoints.append(d.center + n * 0.9)
                waypoints.append(d.center - n * 0.9)
                room = d.otherRoom(from: room)
            }
            waypoints.append(target == world.exitRoom ? world.definition.exit.rect.center : world.rooms[target].rect.center)
        }
    }

    public var finished: Bool { index >= waypoints.count }

    /// Gestures to apply this frame.
    public func step(dt: Double) -> [Gesture] {
        let sim = session.sim
        guard !finished else { return walking ? stopWalking() : [] }
        let target = waypoints[index]
        if sim.position.distance(to: target) < 0.35 {
            index += 1
            return []
        }
        let desired = Heading.of(target - sim.position)
        let delta = Heading.degrees(Heading.wrapDelta(desired - sim.heading))
        var out: [Gesture] = []
        if abs(delta) > 2 {
            let maxTurn = 240 * dt
            let deg = max(-maxTurn, min(maxTurn, delta))
            out.append(.turn(points: deg / session.settings.turnSpeed.degreesPerPoint))
        }
        if abs(delta) > 25 {
            if walking { out += stopWalking() }
        } else if !walking {
            walking = true
            out.append(.walkBegan)
        }
        return out
    }

    private func stopWalking() -> [Gesture] {
        walking = false
        return [.walkEnded]
    }
}
