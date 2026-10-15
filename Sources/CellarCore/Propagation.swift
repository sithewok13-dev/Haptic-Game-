import Foundation

/// How a sound reaches the listener. Sound travels only through openings: a
/// source in another room is heard from the direction of the opening it comes
/// through, at the loudness of the full walking-path distance, and muffled
/// according to how sharply the path bends at each opening. This keeps a hidden
/// source from implying a straight route through a wall.
public struct SoundPath: Equatable {
    /// Where to place the sound so its direction and distance match the path.
    public var apparentPosition: Vec2
    /// Total path length in metres.
    public var length: Double
    /// Linear gain multiplier from the openings (1 = unobstructed).
    public var transmission: Double
    /// 0...1 muffling (low-pass) amount.
    public var muffle: Double
    /// Number of openings on the path.
    public var openings: Int
    /// Points the sound travels through: listener, opening points..., source.
    public var points: [Vec2]
}

public enum Propagation {
    /// Openings beyond this count are treated as inaudible.
    public static let maxOpenings = 4
    /// Distance from an opening over which its effect fades in (keeps changes continuous).
    static let blendDistance = 0.6

    public static func path(in world: World, listener: Vec2, listenerRoom: Int,
                            source: Vec2, sourceRoom: Int) -> SoundPath? {
        if listenerRoom == sourceRoom {
            return SoundPath(apparentPosition: source, length: listener.distance(to: source),
                             transmission: 1, muffle: 0, openings: 0, points: [listener, source])
        }
        guard let doors = shortestDoorSequence(world: world, listener: listener, listenerRoom: listenerRoom,
                                               source: source, sourceRoom: sourceRoom),
              doors.count <= maxOpenings else { return nil }

        // Start from opening centres, then pull the path taut through each aperture.
        var pts = [listener] + doors.map { world.doorways[$0].center } + [source]
        for _ in 0..<3 {
            for i in 1...doors.count {
                pts[i] = aperturePoint(world.doorways[doors[i - 1]].segment, from: pts[i - 1], to: pts[i + 1])
            }
        }

        var length = 0.0
        for i in 0..<(pts.count - 1) { length += pts[i].distance(to: pts[i + 1]) }

        var transmission = 1.0
        var bendTotal = 0.0
        for i in 1...doors.count {
            let inSeg = pts[i] - pts[i - 1]
            let outSeg = pts[i + 1] - pts[i]
            let weight = min(1, min(inSeg.length, outSeg.length) / blendDistance)
            let bend = angleBetween(inSeg, outSeg) * weight
            bendTotal += bend
            // A straight-through opening passes most sound; a sharp corner much less.
            let t = 0.85 - 0.45 * min(1, bend / (Double.pi / 2))
            transmission *= 1 - weight * (1 - t)
        }
        let muffle = min(1, bendTotal / (Double.pi * 0.75))

        // Direction: toward the first opening; when standing in it, toward the next point.
        let toFirst = pts[1] - listener
        let toNext = pts[2] - listener
        let w = min(1, toFirst.length / blendDistance)
        var dir = (toFirst.normalized * w + toNext.normalized * (1 - w)).normalized
        if dir == .zero { dir = toNext.normalized }
        let apparent = listener + dir * length

        return SoundPath(apparentPosition: apparent, length: length, transmission: transmission,
                         muffle: muffle, openings: doors.count, points: pts)
    }

    static func angleBetween(_ a: Vec2, _ b: Vec2) -> Double {
        let la = a.length, lb = b.length
        if la < 1e-9 || lb < 1e-9 { return 0 }
        return acos(max(-1, min(1, a.dot(b) / (la * lb))))
    }

    /// Point within an opening (kept off the jambs) where the line from -> to crosses it,
    /// or the nearest usable point if the line misses.
    static func aperturePoint(_ door: Segment, from p: Vec2, to q: Vec2) -> Vec2 {
        let e = door.b - door.a
        let len = e.length
        let margin = min(0.15, len * 0.25) / len
        let f = q - p
        let denom = e.cross(f)
        var u: Double
        if abs(denom) < 1e-9 {
            u = 0.5
        } else {
            u = (p - door.a).cross(f) / denom
        }
        u = max(margin, min(1 - margin, u))
        return door.a + e * u
    }

    /// Dijkstra over doorways, costed by distance between opening centres.
    static func shortestDoorSequence(world: World, listener: Vec2, listenerRoom: Int,
                                     source: Vec2, sourceRoom: Int) -> [Int]? {
        let n = world.doorways.count
        var dist = Array(repeating: Double.infinity, count: n)
        var prev = Array(repeating: -1, count: n)
        var done = Array(repeating: false, count: n)
        for di in world.doorwaysByRoom[listenerRoom] {
            dist[di] = listener.distance(to: world.doorways[di].center)
        }
        while true {
            var cur = -1
            var best = Double.infinity
            for i in 0..<n where !done[i] && dist[i] < best {
                best = dist[i]
                cur = i
            }
            if cur < 0 { break }
            done[cur] = true
            let d = world.doorways[cur]
            for room in [d.rooms.0, d.rooms.1] {
                for next in world.doorwaysByRoom[room] where next != cur && !done[next] {
                    let cost = dist[cur] + d.center.distance(to: world.doorways[next].center)
                    if cost < dist[next] {
                        dist[next] = cost
                        prev[next] = cur
                    }
                }
            }
        }
        var bestEnd = -1
        var bestTotal = Double.infinity
        for di in world.doorwaysByRoom[sourceRoom] where dist[di] < .infinity {
            let total = dist[di] + world.doorways[di].center.distance(to: source)
            if total < bestTotal {
                bestTotal = total
                bestEnd = di
            }
        }
        guard bestEnd >= 0 else { return nil }
        var seq: [Int] = []
        var cur = bestEnd
        while cur >= 0 {
            seq.append(cur)
            cur = prev[cur]
        }
        return seq.reversed()
    }

    /// Linear gain for a source along a path (inverse-distance beyond the reference distance).
    public static func gain(for path: SoundPath, level: Double, referenceDistance: Double) -> Double {
        let distanceGain = referenceDistance / max(referenceDistance, path.length)
        return level * distanceGain * path.transmission
    }
}
