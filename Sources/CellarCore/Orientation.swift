import Foundation

/// The optional "sense your surroundings" aid. Describes what is immediately
/// around the player (floor, nearby walls, openings in this room, sounds in
/// this room) without naming where any opening leads.
public enum Orientation {
    static let compass = ["north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west"]

    public static func compassWord(headingDegrees: Double) -> String {
        let h = Heading.degrees(Heading.normalized(Heading.radians(headingDegrees)))
        return compass[Int(((h + 22.5) / 45).rounded(.down)) % 8]
    }

    /// "ahead", "ahead to the left", "on your left", "behind you to the left", "behind you".
    public static func relativeWord(bearing: Double) -> String {
        let d = Heading.degrees(Heading.wrapDelta(bearing))
        let a = abs(d)
        let side = d < 0 ? "left" : "right"
        switch a {
        case ..<25: return "ahead"
        case ..<65: return "ahead to the \(side)"
        case ..<115: return "on your \(side)"
        case ..<155: return "behind you to the \(side)"
        default: return "behind you"
        }
    }

    static func distanceWord(_ d: Double) -> String {
        switch d {
        case ..<1.3: return "close"
        case ..<3.2: return "a few steps"
        default: return "farther"
        }
    }

    public static func roomName(_ room: RoomDefinition, capitalized: Bool) -> String {
        let n = room.name ?? room.id
        return capitalized ? n.prefix(1).uppercased() + n.dropFirst() : n
    }

    /// Short spoken summary, most useful first:
    /// "Pump room. Facing north. Wall close on your left. Openings: ahead to the right, a few steps.
    ///  Dripping water: ahead to the left."
    public static func describe(sim: Simulation) -> String {
        let world = sim.world
        let room = world.rooms[sim.room]
        let p = sim.position
        let h = sim.heading
        var parts: [String] = []

        var place = roomName(room, capitalized: true)
        if sim.currentRoomWasVisitedBefore { place += ", again" }
        parts.append(place + ".")
        let underfoot = world.surface(at: p, room: sim.room)
        if underfoot.stairs { parts.append("On stairs.") }
        parts.append("Facing \(compassWord(headingDegrees: sim.headingDegrees)).")

        // Walls within arm's reach or a step.
        var walls: [String] = []
        for (word, offset) in [("ahead", 0.0), ("on your left", -90.0), ("on your right", 90.0)] {
            let dir = Heading.forward(h + Heading.radians(offset))
            if let hit = world.raycast(from: p, direction: dir, maxDistance: 1.2) {
                walls.append(hit.distance < 0.6 ? "touching \(word)" : "close \(word)")
            }
        }
        if !walls.isEmpty { parts.append("Wall " + joinList(walls) + ".") }

        // Openings in this room, nearest first.
        let doors = world.doorwaysByRoom[sim.room]
            .map { world.doorways[$0] }
            .sorted { $0.segment.distance(to: p) < $1.segment.distance(to: p) }
        if doors.contains(where: { $0.segment.distance(to: p) < 0.5 }) {
            parts.append("You are in an opening.")
        }
        let lines = doors.filter { $0.segment.distance(to: p) >= 0.5 }.prefix(3).map { d -> String in
            let lp = ListenerPoint(world: d.center, listener: p, heading: h)
            return "\(relativeWord(bearing: lp.bearing)), \(distanceWord(d.segment.distance(to: p)))"
        }
        if !lines.isEmpty {
            parts.append((lines.count == 1 ? "Opening: " : "Openings: ") + lines.joined(separator: "; ") + ".")
        }

        // Sounds in this room only.
        for s in world.sources where s.room == sim.room {
            guard let name = s.definition.landmark else { continue }
            let lp = ListenerPoint(world: s.position, listener: p, heading: h)
            parts.append("\(name): \(relativeWord(bearing: lp.bearing)).")
        }
        return parts.joined(separator: " ")
    }

    static func joinList(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and " + items.last!
        }
    }
}
