import Foundation

// World coordinates are metres on a flat plan: +x is east, +y is north.
// Headings are radians, 0 = north, increasing clockwise (east = pi/2).

public struct Vec2: Equatable, Codable, CustomStringConvertible {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Vec2(0, 0)

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(a.x * s, a.y * s) }
    public static func / (a: Vec2, s: Double) -> Vec2 { Vec2(a.x / s, a.y / s) }
    public static prefix func - (a: Vec2) -> Vec2 { Vec2(-a.x, -a.y) }

    public var length: Double { (x * x + y * y).squareRoot() }
    public var normalized: Vec2 {
        let l = length
        return l > 1e-12 ? self / l : .zero
    }
    public func dot(_ o: Vec2) -> Double { x * o.x + y * o.y }
    public func cross(_ o: Vec2) -> Double { x * o.y - y * o.x }
    public func distance(to o: Vec2) -> Double { (self - o).length }

    public var description: String { String(format: "(%.2f, %.2f)", x, y) }

    // JSON form: [x, y]
    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x = try c.decode(Double.self)
        y = try c.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(x)
        try c.encode(y)
    }
}

public enum Heading {
    /// Unit vector pointing where a heading faces.
    public static func forward(_ heading: Double) -> Vec2 { Vec2(sin(heading), cos(heading)) }
    /// Unit vector pointing to the right of a heading.
    public static func right(_ heading: Double) -> Vec2 { Vec2(cos(heading), -sin(heading)) }
    /// Heading that faces along a direction vector.
    public static func of(_ direction: Vec2) -> Double { atan2(direction.x, direction.y) }

    /// Normalises to [0, 2pi).
    public static func normalized(_ h: Double) -> Double {
        let twoPi = 2 * Double.pi
        var r = h.truncatingRemainder(dividingBy: twoPi)
        if r < 0 { r += twoPi }
        return r
    }

    /// Wraps an angle difference to (-pi, pi].
    public static func wrapDelta(_ d: Double) -> Double {
        var r = d.truncatingRemainder(dividingBy: 2 * Double.pi)
        if r > Double.pi { r -= 2 * Double.pi }
        if r <= -Double.pi { r += 2 * Double.pi }
        return r
    }

    public static func degrees(_ radians: Double) -> Double { radians * 180 / Double.pi }
    public static func radians(_ degrees: Double) -> Double { degrees * Double.pi / 180 }
}

/// A point expressed relative to the listener: `right` metres to the right,
/// `forward` metres ahead.
public struct ListenerPoint: Equatable {
    public var right: Double
    public var forward: Double

    public init(right: Double, forward: Double) {
        self.right = right
        self.forward = forward
    }

    /// Bearing in radians, 0 = straight ahead, positive = to the right.
    public var bearing: Double { atan2(right, forward) }
    public var distance: Double { (right * right + forward * forward).squareRoot() }

    public init(world p: Vec2, listener: Vec2, heading: Double) {
        let rel = p - listener
        right = rel.dot(Heading.right(heading))
        forward = rel.dot(Heading.forward(heading))
    }
}

public struct Segment: Equatable {
    public var a: Vec2
    public var b: Vec2

    public init(_ a: Vec2, _ b: Vec2) {
        self.a = a
        self.b = b
    }

    public var length: Double { a.distance(to: b) }
    public var midpoint: Vec2 { (a + b) / 2 }

    public func closestPoint(to p: Vec2) -> Vec2 {
        let d = b - a
        let len2 = d.dot(d)
        if len2 < 1e-12 { return a }
        let t = max(0, min(1, (p - a).dot(d) / len2))
        return a + d * t
    }

    public func distance(to p: Vec2) -> Double { closestPoint(to: p).distance(to: p) }

    /// Distance along a ray (origin + t * dir, dir normalised) to this segment, if hit.
    public func rayHit(origin: Vec2, direction: Vec2) -> Double? {
        let e = b - a
        let denom = direction.cross(e)
        if abs(denom) < 1e-12 { return nil }
        let w = a - origin
        let t = w.cross(e) / denom
        let u = w.cross(direction) / denom
        if t >= 0 && u >= -1e-9 && u <= 1 + 1e-9 { return t }
        return nil
    }

    /// True if the open segments p-q and a-b properly intersect.
    public func intersects(_ p: Vec2, _ q: Vec2) -> Bool {
        let r = q - p
        let s = b - a
        let denom = r.cross(s)
        if abs(denom) < 1e-12 { return false }
        let t = (a - p).cross(s) / denom
        let u = (a - p).cross(r) / denom
        return t > 1e-9 && t < 1 - 1e-9 && u > 1e-9 && u < 1 - 1e-9
    }
}

/// Axis-aligned rectangle. JSON form: {"x0":0,"y0":0,"x1":6,"y1":5}.
public struct Rect: Equatable, Codable {
    public var x0: Double
    public var y0: Double
    public var x1: Double
    public var y1: Double

    public init(x0: Double, y0: Double, x1: Double, y1: Double) {
        self.x0 = min(x0, x1)
        self.y0 = min(y0, y1)
        self.x1 = max(x0, x1)
        self.y1 = max(y0, y1)
    }

    public var width: Double { x1 - x0 }
    public var height: Double { y1 - y0 }
    public var center: Vec2 { Vec2((x0 + x1) / 2, (y0 + y1) / 2) }
    public var area: Double { width * height }

    public func contains(_ p: Vec2, inset: Double = 0) -> Bool {
        p.x >= x0 + inset && p.x <= x1 - inset && p.y >= y0 + inset && p.y <= y1 - inset
    }

    public func overlapArea(_ o: Rect) -> Double {
        let w = min(x1, o.x1) - max(x0, o.x0)
        let h = min(y1, o.y1) - max(y0, o.y0)
        return (w > 0 && h > 0) ? w * h : 0
    }

    /// Edges in order south, east, north, west.
    public var edges: [Segment] {
        [
            Segment(Vec2(x0, y0), Vec2(x1, y0)),
            Segment(Vec2(x1, y0), Vec2(x1, y1)),
            Segment(Vec2(x1, y1), Vec2(x0, y1)),
            Segment(Vec2(x0, y1), Vec2(x0, y0)),
        ]
    }
}
