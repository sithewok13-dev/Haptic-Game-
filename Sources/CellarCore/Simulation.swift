import Foundation

/// Physical events produced by moving through the world.
public enum SimEvent: Equatable {
    case footstep(surface: Surface, stairs: Bool, foot: Int, position: Vec2, soft: Bool)
    /// Walked into a wall (once per contact).
    case wallBump(point: Vec2)
    /// Started brushing along a wall at an angle.
    case wallContactBegan(point: Vec2)
    /// Hand brushing the wall while sliding along it (paired with footsteps).
    case wallBrush(point: Vec2)
    /// Moved from one room into another.
    case threshold(from: Int, to: Int)
    /// Feet shuffling while turning in place.
    case pivot
    /// Heading crossed a wall-aligned direction (north/east/south/west).
    case aligned(cardinal: Int)
    case reachedExit
}

public struct MovementTuning: Equatable {
    public var walkSpeed = 1.15
    public var stairSpeed = 0.7
    public var strideLength = 0.68
    public var stairStride = 0.36
    public var snapTurnRate = Heading.radians(300)
    public var pivotSoundEvery = Heading.radians(35)
    /// Walking into a wall more squarely than this (cosine of the angle from its normal;
    /// 0.8 = within about 37 degrees) bounces you back. Shallower contact slides along the wall,
    /// so walking diagonally (45 degrees) follows walls instead of stopping.
    public var bumpApproachCosine = 0.8
    /// Bounce: initial speed (m/s) away from the wall, decay time and how long walking pauses.
    /// Holding to walk then bumps again about twice a second until you turn away.
    public var bounceSpeed = 2.2
    public var bounceDecay = 0.07
    public var bounceDuration = 0.3
    /// Doorway guidance: walking roughly toward an opening (within `doorAssistAngle`, inside
    /// `doorAssistRange` metres) slides you sideways into it at up to `doorAssistSpeed` m/s.
    public var doorAssistRange = 1.4
    public var doorAssistAngle = Heading.radians(55)
    public var doorAssistSpeed = 0.7
    /// Stepping this far away from walls ends a sliding contact.
    public var contactReleaseIdle = 1.2
    public var contactReleaseGap = 0.12
    public init() {}
}

/// Player movement in the invisible world: position, facing, collisions, footsteps, thresholds.
public final class Simulation {
    public let world: World
    public var tuning = MovementTuning()

    public private(set) var position: Vec2
    /// Radians, 0 = north, clockwise.
    public private(set) var heading: Double
    public private(set) var room: Int
    public private(set) var isWalking = false
    public private(set) var reachedExit = false
    public private(set) var visitedRooms: Set<Int> = []
    /// Rooms visited before the most recent entry into the current room.
    public private(set) var currentRoomWasVisitedBefore = false
    public private(set) var distanceWalked = 0.0

    private var unwrappedDegrees: Double
    private var snapRemaining: Double = 0
    private var stride = 0.0
    private var foot = 0
    private var inContact = false
    private var bounceVelocity = Vec2.zero
    private var bounceTime = 0.0
    private var idleTime = 0.0
    private var pivotAccumulator = 0.0
    private var pending: [SimEvent] = []

    public init(world: World) {
        self.world = world
        position = world.definition.start.position
        heading = Heading.normalized(Heading.radians(world.definition.start.headingDegrees))
        unwrappedDegrees = world.definition.start.headingDegrees
        room = world.startRoom
        visitedRooms = [room]
    }

    public func reset() {
        position = world.definition.start.position
        heading = Heading.normalized(Heading.radians(world.definition.start.headingDegrees))
        unwrappedDegrees = world.definition.start.headingDegrees
        room = world.startRoom
        visitedRooms = [room]
        currentRoomWasVisitedBefore = false
        isWalking = false
        reachedExit = false
        snapRemaining = 0
        stride = 0
        inContact = false
        bounceVelocity = .zero
        bounceTime = 0
        idleTime = 0
        pivotAccumulator = 0
        distanceWalked = 0
        pending.removeAll()
    }

    public var headingDegrees: Double { Heading.degrees(heading) }

    public func setWalking(_ walking: Bool) {
        guard walking != isWalking else { return }
        isWalking = walking
        if walking {
            // First step lands quickly so starting to walk is felt at once.
            stride = currentStride * 0.65
        } else if stride > currentStride * 0.3 {
            // A soft settling step confirms the stop.
            let s = world.surface(at: position, room: room)
            pending.append(.footstep(surface: s.surface, stairs: s.stairs, foot: foot, position: position, soft: true))
            foot ^= 1
            stride = 0
        }
    }

    /// Immediate turn by an angle (positive = clockwise / to the right). Cancels any snap turn.
    public func turn(byDegrees degrees: Double) {
        snapRemaining = 0
        applyTurn(degrees)
    }

    /// Turn one step to the right (+1) or left (-1), landing on a multiple of `step` degrees
    /// (45 gives eight directions, 90 the four wall directions). Returns the target heading in degrees.
    @discardableResult
    public func snapTurn(direction: Int, step: Double = 45) -> Double {
        let c = currentTargetDegrees
        // Next grid direction that way; if already within a few degrees of one, the one after.
        let tolerance = min(10, step / 4)
        let target = direction > 0
            ? ((c + tolerance) / step).rounded(.down) * step + step
            : ((c - tolerance) / step).rounded(.up) * step - step
        snapRemaining += target - c
        return Heading.degrees(Heading.normalized(Heading.radians(target)))
    }

    /// Turn around, landing on a multiple of `step` degrees. Returns the target heading in degrees.
    @discardableResult
    public func turnAround(step: Double = 45) -> Double {
        let c = currentTargetDegrees
        let target = ((c + 180) / step).rounded() * step
        snapRemaining += target - c
        return Heading.degrees(Heading.normalized(Heading.radians(target)))
    }

    /// Heading (unwrapped degrees) the player will face once any turn in progress finishes,
    /// so quick repeated swipes add up exactly.
    private var currentTargetDegrees: Double { unwrappedDegrees + snapRemaining }

    public var isSnapTurning: Bool { abs(snapRemaining) > 1e-6 }

    private var currentStride: Double {
        world.surface(at: position, room: room).stairs ? tuning.stairStride : tuning.strideLength
    }

    private func applyTurn(_ degrees: Double) {
        guard degrees != 0 else { return }
        let before = unwrappedDegrees
        let after = before + degrees
        // Wall-aligned crossings (multiples of 90 degrees).
        let eps = 1e-7
        if degrees > 0 {
            let a = (before / 90 + eps).rounded(.down)
            let b = (after / 90 + eps).rounded(.down)
            if b > a { pending.append(.aligned(cardinal: Simulation.cardinalIndex(b))) }
        } else {
            let a = (before / 90 - eps).rounded(.up)
            let b = (after / 90 - eps).rounded(.up)
            if b < a { pending.append(.aligned(cardinal: Simulation.cardinalIndex(b))) }
        }
        unwrappedDegrees = after
        heading = Heading.normalized(Heading.radians(after))
        if !isWalking {
            pivotAccumulator += abs(degrees)
            if pivotAccumulator >= Heading.degrees(tuning.pivotSoundEvery) {
                pivotAccumulator = 0
                pending.append(.pivot)
            }
        }
    }

    static func cardinalIndex(_ k: Double) -> Int {
        let i = Int(k) % 4
        return i < 0 ? i + 4 : i
    }

    /// Advances the simulation. `dt` is clamped so a stall never becomes a jump in position.
    public func update(dt rawDt: Double) -> [SimEvent] {
        let dt = max(0, min(rawDt, 0.05))
        var events = pending
        pending.removeAll()

        if isSnapTurning {
            let stepDeg = Heading.degrees(tuning.snapTurnRate) * dt
            let delta = abs(snapRemaining) <= stepDeg ? snapRemaining : (snapRemaining > 0 ? stepDeg : -stepDeg)
            snapRemaining -= delta
            if abs(snapRemaining) < 1e-6 {
                snapRemaining = 0
                // Land exactly on the wall-aligned heading.
                let target = unwrappedDegrees + delta
                applyTurn(target.rounded() - unwrappedDegrees)
            } else {
                applyTurn(delta)
            }
            events += pending
            pending.removeAll()
        }

        let underfoot = world.surface(at: position, room: room)
        if bounceTime > 0 {
            // Knocked back from a wall: glide away, then walking resumes if still held.
            bounceTime -= dt
            let push = bounceVelocity * dt
            bounceVelocity = bounceVelocity * exp(-dt / tuning.bounceDecay)
            position = moveCircle(from: position, by: push, radius: world.playerRadius, walls: world.walls).position
        } else if isWalking {
            idleTime = 0
            let speed = underfoot.stairs ? tuning.stairSpeed : tuning.walkSpeed
            let stepLength: Double = speed * dt
            let forward = Heading.forward(heading)
            let intended: Vec2 = forward * stepLength
            let assist = doorwayAssist(direction: forward, dt: dt)
            let result = moveCircle(from: position, by: intended + assist, radius: world.playerRadius, walls: world.walls)
            let moved = result.position.distance(to: position)
            position = result.position
            distanceWalked += moved
            let strideLen = underfoot.stairs ? tuning.stairStride : tuning.strideLength

            if let contact = result.contacts.max(by: { a, b in
                a.normal.dot(-intended) < b.normal.dot(-intended)
            }) {
                let squareness = contact.normal.dot(-forward)
                let noProgress = moved < intended.length * 0.25
                if squareness >= tuning.bumpApproachCosine || noProgress {
                    // Head-on (or wedged in a corner): bounce back.
                    events.append(.wallBump(point: contact.point))
                    var away = contact.normal
                    if noProgress && squareness < tuning.bumpApproachCosine { away = -forward }
                    bounceVelocity = away * tuning.bounceSpeed
                    bounceTime = tuning.bounceDuration
                    inContact = false
                    stride = strideLen * 0.5
                } else if !inContact {
                    inContact = true
                    events.append(.wallContactBegan(point: contact.point))
                }
            } else if inContact && world.nearestWallDistance(to: position) > world.playerRadius + tuning.contactReleaseGap {
                inContact = false
            }

            // Footsteps only for real progress, not for pushing against a wall.
            if bounceTime <= 0 && moved > intended.length * 0.2 {
                stride += moved
                if stride >= strideLen {
                    stride -= strideLen
                    let s = world.surface(at: position, room: room)
                    events.append(.footstep(surface: s.surface, stairs: s.stairs, foot: foot, position: position, soft: false))
                    if inContact, let c = result.contacts.first {
                        events.append(.wallBrush(point: c.point))
                    }
                    foot ^= 1
                }
            }
        } else {
            idleTime += dt
            if inContact && idleTime >= tuning.contactReleaseIdle { inContact = false }
        }

        if let newRoom = world.room(at: position, current: room), newRoom != room {
            let previous = room
            room = newRoom
            currentRoomWasVisitedBefore = visitedRooms.contains(newRoom)
            visitedRooms.insert(newRoom)
            events.append(.threshold(from: previous, to: newRoom))
        }

        if !reachedExit && room == world.exitRoom && world.definition.exit.rect.contains(position) {
            reachedExit = true
            isWalking = false
            events.append(.reachedExit)
        }
        return events
    }

    /// Sideways nudge toward the clear part of a nearby opening the player is walking toward,
    /// so imprecise aim (only eight directions) still passes through doorways.
    private func doorwayAssist(direction f: Vec2, dt: Double) -> Vec2 {
        var best = Vec2.zero
        var bestAhead = Double.infinity
        for di in world.doorwaysByRoom[room] {
            let d = world.doorways[di]
            let axis = (d.segment.b - d.segment.a).normalized
            let rel = position - d.center
            var n = Vec2(-axis.y, axis.x)
            if rel.dot(n) > 0 { n = -n }          // n points from the player's side through the opening
            let ahead = -rel.dot(n)
            guard ahead < tuning.doorAssistRange, f.dot(n) > cos(tuning.doorAssistAngle) else { continue }
            let lateral = rel.dot(axis)
            guard abs(lateral) < d.width / 2 + 0.7 else { continue }
            let half = max(0, d.width / 2 - world.playerRadius - 0.08)
            let excess = lateral > half ? lateral - half : (lateral < -half ? lateral + half : 0)
            guard excess != 0, ahead < bestAhead else { continue }
            let shift = min(abs(excess), tuning.doorAssistSpeed * dt)
            best = axis * (excess > 0 ? -shift : shift)
            bestAhead = ahead
        }
        return best
    }

    /// Debug/test helper: place the player directly.
    public func teleport(to p: Vec2, headingDegrees: Double) {
        position = p
        heading = Heading.normalized(Heading.radians(headingDegrees))
        unwrappedDegrees = headingDegrees
        if let r = world.room(at: p) { room = r }
        visitedRooms.insert(room)
    }
}
