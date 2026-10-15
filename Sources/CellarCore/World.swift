import Foundation

public struct Wall: Equatable {
    public var segment: Segment
    public var room: Int
}

public struct Doorway: Equatable {
    public var id: String
    public var rooms: (Int, Int)
    public var segment: Segment
    public var center: Vec2 { segment.midpoint }
    public var width: Double { segment.length }

    public func otherRoom(from room: Int) -> Int { room == rooms.0 ? rooms.1 : rooms.0 }

    public static func == (l: Doorway, r: Doorway) -> Bool {
        l.id == r.id && l.rooms == r.rooms && l.segment == r.segment
    }
}

public struct SoundSource: Equatable {
    public var definition: SoundSourceDefinition
    public var room: Int
    public var id: String { definition.id }
    public var position: Vec2 { definition.position }
}

public enum WorldError: Error, CustomStringConvertible {
    case invalid([String])
    public var description: String {
        switch self {
        case .invalid(let issues): return "Invalid world:\n" + issues.joined(separator: "\n")
        }
    }
}

/// Compiled, queryable world: invisible geometry derived from the definition.
/// Every room is a convex rectangle, so anything inside one room is in direct
/// line of sight of anything else in that room; rooms connect only through doorways.
public final class World {
    public let definition: WorldDefinition
    public let rooms: [RoomDefinition]
    public let doorways: [Doorway]
    public let walls: [Wall]
    public let sources: [SoundSource]
    public let exitRoom: Int
    public let startRoom: Int
    public var playerRadius: Double { definition.playerRadius }

    /// Doorway indices touching each room.
    public let doorwaysByRoom: [[Int]]

    public init(_ def: WorldDefinition) throws {
        definition = def
        rooms = def.rooms
        var issues: [String] = []

        func roomIndex(_ id: String) -> Int? { def.rooms.firstIndex { $0.id == id } }

        // Doorways.
        var doors: [Doorway] = []
        for d in def.doorways {
            guard d.rooms.count == 2, let r0 = roomIndex(d.rooms[0]), let r1 = roomIndex(d.rooms[1]) else {
                issues.append("Doorway \(d.id) must name two existing rooms")
                continue
            }
            doors.append(Doorway(id: d.id, rooms: (r0, r1), segment: Segment(d.a, d.b)))
        }
        doorways = doors

        var byRoom = Array(repeating: [Int](), count: def.rooms.count)
        for (i, d) in doors.enumerated() {
            byRoom[d.rooms.0].append(i)
            byRoom[d.rooms.1].append(i)
        }
        doorwaysByRoom = byRoom

        // Walls: each room edge minus the openings that lie on it.
        var wallList: [Wall] = []
        for (ri, room) in def.rooms.enumerated() {
            for edge in room.rect.edges {
                for piece in World.subtractOpenings(edge: edge, openings: byRoom[ri].map { doors[$0].segment }) {
                    wallList.append(Wall(segment: piece, room: ri))
                }
            }
        }
        walls = wallList

        var srcs: [SoundSource] = []
        for s in def.sources {
            if let r = def.rooms.firstIndex(where: { $0.rect.contains(s.position, inset: 0.01) }) {
                srcs.append(SoundSource(definition: s, room: r))
            } else {
                issues.append("Sound source \(s.id) is not inside any room")
            }
        }
        sources = srcs

        exitRoom = roomIndex(def.exit.room) ?? -1
        startRoom = def.rooms.firstIndex { $0.rect.contains(def.start.position, inset: def.playerRadius) } ?? -1
        if exitRoom < 0 { issues.append("Exit room \(def.exit.room) does not exist") }
        if startRoom < 0 { issues.append("Start position must be inside a room, clear of its walls") }

        issues += validate()
        if !issues.isEmpty { throw WorldError.invalid(issues) }
    }

    /// Splits an edge into wall pieces, removing any opening collinear with it.
    static func subtractOpenings(edge: Segment, openings: [Segment]) -> [Segment] {
        let dir = edge.b - edge.a
        let len = dir.length
        let unit = dir / len
        var gaps: [(Double, Double)] = []
        for o in openings {
            // Both jambs must lie on the edge line (perpendicular distance ~ 0).
            let da = abs((o.a - edge.a).cross(unit))
            let db = abs((o.b - edge.a).cross(unit))
            guard da < 1e-6, db < 1e-6 else { continue }
            let ta = (o.a - edge.a).dot(unit)
            let tb = (o.b - edge.a).dot(unit)
            let lo = max(0, min(ta, tb))
            let hi = min(len, max(ta, tb))
            if hi - lo > 1e-6 { gaps.append((lo, hi)) }
        }
        gaps.sort { $0.0 < $1.0 }
        var pieces: [Segment] = []
        var cursor = 0.0
        for g in gaps {
            if g.0 - cursor > 1e-6 {
                pieces.append(Segment(edge.a + unit * cursor, edge.a + unit * g.0))
            }
            cursor = max(cursor, g.1)
        }
        if len - cursor > 1e-6 {
            pieces.append(Segment(edge.a + unit * cursor, edge.b))
        }
        return pieces
    }

    func validate() -> [String] {
        var issues: [String] = []
        let r = playerRadius
        for i in 0..<rooms.count {
            for j in (i + 1)..<rooms.count where rooms[i].rect.overlapArea(rooms[j].rect) > 1e-9 {
                issues.append("Rooms \(rooms[i].id) and \(rooms[j].id) overlap")
            }
            if rooms[i].rect.width < 4 * r || rooms[i].rect.height < 4 * r {
                issues.append("Room \(rooms[i].id) is too small to turn around in")
            }
        }
        for d in doorways {
            for ri in [d.rooms.0, d.rooms.1] {
                let onEdge = rooms[ri].rect.edges.contains { edge in
                    edge.distance(to: d.segment.a) < 1e-6 && edge.distance(to: d.segment.b) < 1e-6
                }
                if !onEdge { issues.append("Doorway \(d.id) does not lie on an edge of \(rooms[ri].id)") }
            }
            if d.width < 2 * r + 0.3 {
                issues.append("Doorway \(d.id) is too narrow (\(d.width) m)")
            }
        }
        // Graph connectivity: every room reachable from the start room.
        if startRoom >= 0 {
            var seen: Set<Int> = [startRoom]
            var queue = [startRoom]
            while let cur = queue.popLast() {
                for di in doorwaysByRoom[cur] {
                    let next = doorways[di].otherRoom(from: cur)
                    if seen.insert(next).inserted { queue.append(next) }
                }
            }
            for (i, room) in rooms.enumerated() where !seen.contains(i) {
                issues.append("Room \(room.id) is not connected to the start")
            }
        }
        return issues
    }

    // MARK: - Queries

    /// Room containing a point, preferring `current` when the point sits on a shared boundary.
    public func room(at p: Vec2, current: Int? = nil) -> Int? {
        if let c = current, c >= 0, c < rooms.count, rooms[c].rect.contains(p) { return c }
        return rooms.firstIndex { $0.rect.contains(p) }
    }

    /// Surface and stairs flag underfoot.
    public func surface(at p: Vec2, room: Int) -> (surface: Surface, stairs: Bool) {
        let r = rooms[room]
        if let zones = r.zones {
            for z in zones where z.rect.contains(p) {
                return (z.surface, z.stairs ?? false)
            }
        }
        return (r.surface, false)
    }

    public struct RayHit {
        public var distance: Double
        public var point: Vec2
    }

    /// Nearest wall along a ray. Openings let rays pass.
    public func raycast(from origin: Vec2, direction: Vec2, maxDistance: Double) -> RayHit? {
        let dir = direction.normalized
        var best: Double = .infinity
        for w in walls {
            if let t = w.segment.rayHit(origin: origin, direction: dir), t < best { best = t }
        }
        guard best <= maxDistance else { return nil }
        return RayHit(distance: best, point: origin + dir * best)
    }

    public func nearestWallDistance(to p: Vec2) -> Double {
        walls.reduce(Double.infinity) { min($0, $1.segment.distance(to: p)) }
    }

    /// True if a straight line between two points crosses no wall.
    public func hasLineOfSight(_ p: Vec2, _ q: Vec2) -> Bool {
        !walls.contains { $0.segment.intersects(p, q) }
    }

    /// Shortest room sequence (via doorways) between two rooms; used by tests and the autopilot.
    public func doorwayRoute(from a: Int, to b: Int) -> [Int]? {
        if a == b { return [] }
        var prev: [Int: (room: Int, door: Int)] = [:]
        var queue = [a]
        var seen: Set<Int> = [a]
        var head = 0
        while head < queue.count {
            let cur = queue[head]
            head += 1
            for di in doorwaysByRoom[cur] {
                let next = doorways[di].otherRoom(from: cur)
                if seen.insert(next).inserted {
                    prev[next] = (cur, di)
                    queue.append(next)
                }
            }
        }
        guard seen.contains(b) else { return nil }
        var route: [Int] = []
        var cur = b
        while cur != a, let p = prev[cur] {
            route.append(p.door)
            cur = p.room
        }
        return route.reversed()
    }
}
