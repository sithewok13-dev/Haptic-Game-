import Foundation

/// Render parameters for one spatial voice, in listener space.
public struct VoiceParams: Equatable {
    public var position: ListenerPoint
    /// Linear gain.
    public var gain: Double
    /// 0...1 low-pass muffling.
    public var muffle: Double
    public var reverbBlend: Double
}

/// Computes what every looping voice should sound like this frame:
/// world sources routed through openings, plus the optional wall-sense probes.
/// Positions are smoothed in world space (so path changes glide) and then
/// transformed into listener space (so turning is immediate and landmarks stay put).
public final class AudioScene {
    public let world: World
    /// Directions of the wall-sense probes relative to facing (degrees).
    public static let probeAngles: [Double] = [-90, 0, 90]
    public static let probeRange = 1.9
    public var probeLevel = 0.22

    private struct Smoothed {
        var position: Vec2
        var gain: Double
        var muffle: Double
    }

    private var sourceState: [Smoothed?]
    private var probeState: [Smoothed?]

    public init(world: World) {
        self.world = world
        sourceState = Array(repeating: nil, count: world.sources.count)
        probeState = Array(repeating: nil, count: AudioScene.probeAngles.count)
    }

    /// Forget smoothing (after restart or resume) so nothing glides from a stale place.
    public func reset() {
        sourceState = Array(repeating: nil, count: world.sources.count)
        probeState = Array(repeating: nil, count: AudioScene.probeAngles.count)
    }

    /// Unsmoothed target for one source.
    public func target(for source: SoundSource, listener: Vec2, room: Int) -> (position: Vec2, gain: Double, muffle: Double) {
        guard let path = Propagation.path(in: world, listener: listener, listenerRoom: room,
                                          source: source.position, sourceRoom: source.room) else {
            return (source.position, 0, 1)
        }
        let d = source.definition
        return (path.apparentPosition, Propagation.gain(for: path, level: d.level, referenceDistance: d.referenceDistance), path.muffle)
    }

    public func update(listener: Vec2, heading: Double, room: Int, dt: Double, wallSense: Bool)
        -> (sources: [VoiceParams], probes: [VoiceParams]) {
        let k = dt <= 0 ? 1 : min(1, dt / 0.12)

        var sources: [VoiceParams] = []
        for (i, s) in world.sources.enumerated() {
            let t = target(for: s, listener: listener, room: room)
            var st = sourceState[i] ?? Smoothed(position: t.position, gain: t.gain, muffle: t.muffle)
            st.position = st.position + (t.position - st.position) * k
            st.gain += (t.gain - st.gain) * k
            st.muffle += (t.muffle - st.muffle) * k
            sourceState[i] = st
            sources.append(VoiceParams(position: ListenerPoint(world: st.position, listener: listener, heading: heading),
                                       gain: st.gain, muffle: st.muffle, reverbBlend: s.definition.reverbBlend))
        }

        var probes: [VoiceParams] = []
        for (i, angle) in AudioScene.probeAngles.enumerated() {
            let dir = Heading.forward(heading + Heading.radians(angle))
            var targetPos = listener + dir * AudioScene.probeRange
            var targetGain = 0.0
            if wallSense, let hit = world.raycast(from: listener, direction: dir, maxDistance: AudioScene.probeRange) {
                let near = max(0, min(1, (AudioScene.probeRange - hit.distance) / (AudioScene.probeRange - world.playerRadius)))
                targetGain = probeLevel * near * near * (angle == 0 ? 0.8 : 1)
                targetPos = hit.point
            }
            // Probes follow the player directly (they're relative by nature); only gain glides.
            var st = probeState[i] ?? Smoothed(position: targetPos, gain: targetGain, muffle: 0)
            st.position = targetPos
            st.gain += (targetGain - st.gain) * min(1, k * 0.8)
            probeState[i] = st
            var lp = ListenerPoint(world: st.position, listener: listener, heading: heading)
            // Keep a minimum rendering distance so HRTF direction stays stable.
            let dist = lp.distance
            if dist < 0.5 && dist > 1e-6 {
                lp = ListenerPoint(right: lp.right / dist * 0.5, forward: lp.forward / dist * 0.5)
            }
            probes.append(VoiceParams(position: lp, gain: st.gain, muffle: 0.3, reverbBlend: 0.05))
        }
        return (sources, probes)
    }
}
