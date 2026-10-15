import Foundation

public struct Contact: Equatable {
    /// Point on the wall that was touched.
    public var point: Vec2
    /// Unit normal pointing from the wall toward the player.
    public var normal: Vec2
}

public struct MoveResult: Equatable {
    public var position: Vec2
    public var contacts: [Contact]
}

/// Moves a circle of `radius` by `delta`, sliding along walls rather than passing through them.
/// Sub-steps keep each step well under the radius, so thin (zero-thickness) walls cannot be tunnelled.
public func moveCircle(from start: Vec2, by delta: Vec2, radius: Double, walls: [Wall]) -> MoveResult {
    let maxStep = radius * 0.25
    let steps = max(1, Int((delta.length / maxStep).rounded(.up)))
    let stepDelta = delta / Double(steps)
    var pos = start
    var contacts: [Contact] = []

    for _ in 0..<steps {
        let before = pos
        pos = pos + stepDelta
        for _ in 0..<4 {
            var pushed = false
            for w in walls {
                let c = w.segment.closestPoint(to: pos)
                let diff = pos - c
                let d = diff.length
                if d < radius - 1e-9 {
                    var n: Vec2
                    if d > 1e-9 {
                        n = diff / d
                    } else {
                        // Exactly on the wall: push back toward where we came from.
                        let e = (w.segment.b - w.segment.a).normalized
                        n = Vec2(-e.y, e.x)
                        if (before - c).dot(n) < 0 { n = -n }
                    }
                    pos = c + n * radius
                    pushed = true
                    if !contacts.contains(where: { $0.point.distance(to: c) < 0.05 }) {
                        contacts.append(Contact(point: c, normal: n))
                    }
                }
            }
            if !pushed { break }
        }
    }
    return MoveResult(position: pos, contacts: contacts)
}
