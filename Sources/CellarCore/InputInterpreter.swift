import Foundation

/// Raw touch input, in screen points and seconds.
public enum TouchPhase { case began, moved, ended, cancelled }

public struct TouchSample {
    public var id: Int
    public var phase: TouchPhase
    public var x: Double
    public var y: Double
    public init(id: Int, phase: TouchPhase, x: Double, y: Double) {
        self.id = id
        self.phase = phase
        self.x = x
        self.y = y
    }
}

public enum SwipeDirection: Equatable { case left, right, up, down }

/// The small, eyes-free gesture vocabulary.
public enum Gesture: Equatable {
    /// One finger held still: start walking.
    case walkBegan
    /// Finger lifted (or a second finger landed): stop walking.
    case walkEnded
    /// Horizontal drag in points (positive = right).
    case turn(points: Double)
    case tap
    case doubleTap
    /// Quick one-finger flick (used in menus).
    case swipe(SwipeDirection)
    case twoFingerTap
    case twoFingerSwipe(SwipeDirection)
    case twoFingerHold
}

public struct InputTuning: Equatable {
    /// Hold still this long before walking starts.
    public var walkDelay = 0.18
    /// Movement (points) before a touch is treated as a drag rather than a hold.
    public var dragSlop = 12.0
    public var tapMaxDuration = 0.3
    public var doubleTapWindow = 0.4
    public var swipeMinDistance = 40.0
    public var swipeMaxDuration = 0.45
    public var twoFingerHoldTime = 0.8
    public var twoFingerHoldSlop = 25.0
    /// Fingers landing within this window count as one multi-finger gesture.
    public var multiFingerWindow = 0.15
    public init() {}
}

/// Turns raw touches into gestures. Pure logic so it can be unit tested.
///
/// Rules (designed to avoid accidental motion):
/// - A touch that stays still for `walkDelay` walks; lifting stops at once.
/// - A touch that starts by dragging sideways only turns; it never starts walking.
/// - While walking, sideways drag steers.
/// - Any second finger stops walking and makes the whole touch a two-finger gesture.
public final class InputInterpreter {
    public var tuning = InputTuning()

    private enum Mode { case idle, pending, walking, dragging, multi }

    private struct Track {
        var startX: Double, startY: Double
        var x: Double, y: Double
    }

    private var mode: Mode = .idle
    private var touches: [Int: Track] = [:]
    private var primary: Int?
    private var startTime = 0.0
    private var multiFired = false
    private var multiCount = 0
    private var lastTapTime = -10.0

    public init() {}

    public var isWalking: Bool { mode == .walking }

    /// Forget all touches (e.g. on pause or backgrounding). Emits walkEnded if needed.
    public func reset() -> [Gesture] {
        let wasWalking = mode == .walking
        touches.removeAll()
        primary = nil
        mode = .idle
        multiFired = false
        return wasWalking ? [.walkEnded] : []
    }

    public func handle(_ samples: [TouchSample], time: Double) -> [Gesture] {
        var out: [Gesture] = []
        for s in samples { out += handle(s, time: time) }
        return out
    }

    public func handle(_ s: TouchSample, time: Double) -> [Gesture] {
        var out: [Gesture] = []
        switch s.phase {
        case .began:
            touches[s.id] = Track(startX: s.x, startY: s.y, x: s.x, y: s.y)
            switch mode {
            case .idle:
                mode = .pending
                primary = s.id
                startTime = time
            case .pending, .walking, .dragging:
                if mode == .walking { out.append(.walkEnded) }
                // A late second finger after a long single-finger touch is still treated
                // as two-finger, but timing for tap/hold restarts now.
                if time - startTime > tuning.multiFingerWindow { startTime = time }
                for k in touches.keys {
                    touches[k]!.startX = touches[k]!.x
                    touches[k]!.startY = touches[k]!.y
                }
                mode = .multi
                multiFired = false
                multiCount = touches.count
            case .multi:
                multiCount = max(multiCount, touches.count)
            }

        case .moved:
            guard var t = touches[s.id] else { return [] }
            let dx = s.x - t.x
            t.x = s.x
            t.y = s.y
            touches[s.id] = t
            guard s.id == primary else { break }
            switch mode {
            case .pending:
                let tx = t.x - t.startX, ty = t.y - t.startY
                if (tx * tx + ty * ty).squareRoot() > tuning.dragSlop {
                    mode = .dragging
                    if abs(tx) >= abs(ty) { out.append(.turn(points: tx)) }
                }
            case .walking:
                out.append(.turn(points: dx))
            case .dragging:
                let tx = t.x - t.startX, ty = t.y - t.startY
                // Only sideways movement turns; mostly-vertical drags are ignored.
                if abs(tx) >= abs(ty) * 0.5 { out.append(.turn(points: dx)) }
            default:
                break
            }

        case .ended, .cancelled:
            guard var t = touches[s.id] else { return [] }
            t.x = s.x
            t.y = s.y
            touches[s.id] = t
            let duration = time - startTime
            switch mode {
            case .pending:
                if s.phase == .ended && duration <= tuning.tapMaxDuration {
                    out.append(.tap)
                    if time - lastTapTime <= tuning.doubleTapWindow {
                        out.append(.doubleTap)
                        lastTapTime = -10
                    } else {
                        lastTapTime = time
                    }
                }
            case .walking:
                out.append(.walkEnded)
            case .dragging:
                let tx = t.x - t.startX, ty = t.y - t.startY
                if s.phase == .ended && duration <= tuning.swipeMaxDuration,
                   let dir = InputInterpreter.direction(tx, ty, min: tuning.swipeMinDistance) {
                    out.append(.swipe(dir))
                }
            case .multi:
                if !multiFired && s.phase == .ended && multiCount == 2 {
                    let (mx, my) = meanDisplacement()
                    if let dir = InputInterpreter.direction(mx, my, min: tuning.swipeMinDistance) {
                        out.append(.twoFingerSwipe(dir))
                    } else if duration <= tuning.tapMaxDuration + 0.1 {
                        out.append(.twoFingerTap)
                    }
                }
                multiFired = true
            case .idle:
                break
            }
            touches[s.id] = nil
            if touches.isEmpty {
                mode = .idle
                primary = nil
            } else if mode != .multi {
                // A leftover finger never walks.
                mode = .multi
                multiFired = true
            }
        }
        return out
    }

    /// Call every frame; timers fire walking and two-finger holds.
    public func tick(time: Double) -> [Gesture] {
        switch mode {
        case .pending:
            if time - startTime >= tuning.walkDelay {
                mode = .walking
                return [.walkBegan]
            }
        case .multi:
            if !multiFired && multiCount == 2 && time - startTime >= tuning.twoFingerHoldTime {
                let (mx, my) = meanDisplacement()
                if (mx * mx + my * my).squareRoot() < tuning.twoFingerHoldSlop {
                    multiFired = true
                    return [.twoFingerHold]
                }
            }
        default:
            break
        }
        return []
    }

    private func meanDisplacement() -> (Double, Double) {
        guard !touches.isEmpty else { return (0, 0) }
        var sx = 0.0, sy = 0.0
        for t in touches.values {
            sx += t.x - t.startX
            sy += t.y - t.startY
        }
        return (sx / Double(touches.count), sy / Double(touches.count))
    }

    static func direction(_ dx: Double, _ dy: Double, min: Double) -> SwipeDirection? {
        if abs(dx) < min && abs(dy) < min { return nil }
        if abs(dx) >= abs(dy) { return dx > 0 ? .right : .left }
        // Screen y grows downward.
        return dy > 0 ? .down : .up
    }
}
