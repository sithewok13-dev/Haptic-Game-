import Foundation

/// Procedurally generated sound set, so the game works offline with no
/// downloaded assets. Every sound is mono Float samples. Any id here can be
/// replaced by bundling an audio file with the same name (see README).
public enum SoundSynth {
    public static let sampleRate = 44_100.0

    /// Looping beds placed in the world.
    public static let loopIDs = ["drip", "pipeGroan", "ventHum", "buzz", "wind", "outdoor",
                                 "wallPresence.0", "wallPresence.1", "wallPresence.2"]
    public static let footstepVariants = 4
    public static let oneShotIDs: [String] = {
        var ids = ["bump", "brush", "pivot", "threshold", "alignClick", "completion", "menuTick"]
        for s in Surface.allCases {
            for v in 0..<footstepVariants { ids.append(footstepID(s, v)) }
        }
        return ids
    }()
    public static var allIDs: [String] { loopIDs + oneShotIDs }

    public static func footstepID(_ s: Surface, _ variant: Int) -> String { "step.\(s.rawValue).\(variant)" }

    public static func render(_ id: String) -> [Float] {
        switch id {
        case "drip": return drip()
        case "pipeGroan": return pipeGroan()
        case "ventHum": return ventHum()
        case "buzz": return buzz()
        case "wind": return wind()
        case "outdoor": return outdoor()
        case "bump": return bump()
        case "brush": return brush()
        case "pivot": return pivot()
        case "threshold": return threshold()
        case "alignClick", "menuTick": return click(freq: id == "menuTick" ? 1800 : 2600)
        case "completion": return completion()
        default:
            if id.hasPrefix("wallPresence.") {
                return wallPresence(seed: UInt64(id.split(separator: ".").last.flatMap { Int($0) } ?? 0))
            }
            if id.hasPrefix("step.") {
                let parts = id.split(separator: ".")
                if parts.count == 3, let s = Surface(rawValue: String(parts[1])), let v = Int(parts[2]) {
                    return footstep(s, variant: v)
                }
            }
            return [Float](repeating: 0, count: 64)
        }
    }

    // MARK: - DSP helpers

    struct RNG {
        var state: UInt64
        init(_ seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        /// Uniform in [0, 1).
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        /// Uniform in [-1, 1).
        mutating func bipolar() -> Double { unit() * 2 - 1 }
        mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * unit() }
    }

    struct Biquad {
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        enum Kind { case lowpass, highpass, bandpass }

        init(_ kind: Kind, freq: Double, q: Double = 0.707) {
            let w0 = 2 * Double.pi * min(freq, sampleRate * 0.45) / sampleRate
            let alpha = sin(w0) / (2 * q)
            let c = cos(w0)
            var nb0, nb1, nb2: Double
            switch kind {
            case .lowpass:
                nb0 = (1 - c) / 2; nb1 = 1 - c; nb2 = (1 - c) / 2
            case .highpass:
                nb0 = (1 + c) / 2; nb1 = -(1 + c); nb2 = (1 + c) / 2
            case .bandpass:
                nb0 = alpha; nb1 = 0; nb2 = -alpha
            }
            let a0 = 1 + alpha
            b0 = nb0 / a0; b1 = nb1 / a0; b2 = nb2 / a0
            a1 = -2 * c / a0; a2 = (1 - alpha) / a0
        }

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x
            y2 = y1; y1 = y
            return y
        }
    }

    static func samples(_ seconds: Double) -> Int { Int(seconds * sampleRate) }

    static func normalize(_ x: inout [Double], peak: Double) {
        let m = x.reduce(0) { max($0, abs($1)) }
        guard m > 1e-9 else { return }
        let g = peak / m
        for i in x.indices { x[i] *= g }
    }

    static func toFloat(_ x: [Double]) -> [Float] { x.map { Float($0) } }

    /// Makes a seamless loop: renders `body + fade` seconds via `make`, then folds the tail over the head.
    static func loop(seconds: Double, fade: Double = 0.5, peak: Double, _ make: (Int) -> [Double]) -> [Float] {
        let n = samples(seconds)
        let f = samples(fade)
        var x = make(n + f)
        for i in 0..<f {
            let t = Double(i) / Double(f)
            let fadeIn = sin(t * Double.pi / 2)
            let fadeOut = cos(t * Double.pi / 2)
            x[i] = x[i] * fadeIn + x[n + i] * fadeOut
        }
        x.removeLast(f)
        normalize(&x, peak: peak)
        return toFloat(x)
    }

    static func add(_ x: inout [Double], at start: Int, _ y: [Double], gain: Double = 1) {
        for (i, v) in y.enumerated() where start + i < x.count && start + i >= 0 {
            x[start + i] += v * gain
        }
    }

    static func noise(_ n: Int, _ rng: inout RNG) -> [Double] {
        (0..<n).map { _ in rng.bipolar() }
    }

    static func filtered(_ x: [Double], _ filters: [Biquad]) -> [Double] {
        var fs = filters
        return x.map { v in
            var y = v
            for i in fs.indices { y = fs[i].process(y) }
            return y
        }
    }

    /// Damped sine partial.
    static func ping(freq: Double, decay: Double, seconds: Double, amp: Double = 1, glide: Double = 0) -> [Double] {
        let n = samples(seconds)
        var phase = 0.0
        return (0..<n).map { i in
            let t = Double(i) / sampleRate
            phase += 2 * Double.pi * freq * (1 + glide * t) / sampleRate
            return sin(phase) * exp(-t / decay) * amp
        }
    }

    /// Noise burst with exponential decay through a filter.
    static func burst(_ rng: inout RNG, seconds: Double, decay: Double, attack: Double = 0.002,
                      filters: [Biquad], amp: Double = 1) -> [Double] {
        let n = samples(seconds)
        let raw = noise(n, &rng).enumerated().map { i, v -> Double in
            let t = Double(i) / sampleRate
            let a = t < attack ? t / attack : 1
            return v * a * exp(-t / decay) * amp
        }
        return filtered(raw, filters)
    }

    // MARK: - Landmark loops

    /// Water drops falling into a puddle at irregular intervals.
    static func drip() -> [Float] {
        var rng = RNG(11)
        return loop(seconds: 8.0, fade: 0.05, peak: 0.9) { n in
            var x = [Double](repeating: 0, count: n)
            let times = [0.35, 1.75, 2.9, 4.55, 5.35, 6.95]
            for t in times {
                let start = samples(t + rng.range(-0.05, 0.05))
                let f0 = rng.range(1050, 1500)
                // Bubble resonance: a short upward-gliding sine.
                add(&x, at: start, ping(freq: f0, decay: 0.022, seconds: 0.12, amp: 0.9, glide: 5))
                // Impact tick and tiny splash.
                add(&x, at: start, burst(&rng, seconds: 0.03, decay: 0.004,
                                         filters: [Biquad(.highpass, freq: 2500)], amp: 0.5))
                add(&x, at: start + samples(0.004), burst(&rng, seconds: 0.08, decay: 0.02,
                                                          filters: [Biquad(.bandpass, freq: 3800, q: 1.2)], amp: 0.25))
            }
            return x
        }
    }

    /// Occasional groan of old pipes and a distant knock; mostly silence.
    static func pipeGroan() -> [Float] {
        var rng = RNG(23)
        return loop(seconds: 15, fade: 0.2, peak: 0.8) { n in
            var x = [Double](repeating: 0, count: n)
            // Groan: buzzy low tone with wandering pitch, shaped by resonances.
            let gStart = samples(2.5), gLen = samples(2.4)
            var phase = 0.0
            var groan = [Double](repeating: 0, count: gLen)
            for i in 0..<gLen {
                let t = Double(i) / sampleRate
                let f = 62 + 9 * sin(2 * Double.pi * 0.45 * t) + 5 * sin(2 * Double.pi * 1.7 * t)
                phase += 2 * Double.pi * f / sampleRate
                var v = 0.0
                for h in 1...12 { v += sin(phase * Double(h)) / Double(h) }
                let env = min(1, t / 0.5) * min(1, (2.4 - t) / 0.9)
                groan[i] = v * max(0, env)
            }
            let dry = groan
            let resonant = filtered(dry, [Biquad(.bandpass, freq: 420, q: 2.5)])
            add(&x, at: gStart, resonant, gain: 1.0)
            add(&x, at: gStart, dry, gain: 0.15)
            // Distant knock.
            let k = samples(10.2)
            add(&x, at: k, ping(freq: 105, decay: 0.07, seconds: 0.4, amp: 0.6))
            add(&x, at: k, ping(freq: 233, decay: 0.04, seconds: 0.3, amp: 0.3))
            add(&x, at: k + samples(0.21), ping(freq: 110, decay: 0.06, seconds: 0.4, amp: 0.35))
            return x
        }
    }

    /// Ventilation fan: motor hum, blade-pass throb and airflow.
    static func ventHum() -> [Float] {
        var rng = RNG(37)
        return loop(seconds: 4, fade: 0.4, peak: 0.7) { n in
            let air = filtered(noise(n, &rng), [Biquad(.lowpass, freq: 900), Biquad(.highpass, freq: 120)])
            return (0..<n).map { i in
                let t = Double(i) / sampleRate
                let w = 2 * Double.pi * t
                let motor = 0.5 * sin(w * 50) + 0.35 * sin(w * 100) + 0.18 * sin(w * 150)
                    + 0.08 * sin(w * 200) + 0.05 * sin(w * 300)
                let throb = 1 + 0.3 * sin(w * 12.5)
                let wobble = 1 + 0.1 * sin(w * 0.75)
                return motor * 0.6 * wobble + air[i] * 1.6 * throb
            }
        }
    }

    /// A failing fluorescent light: mains buzz with irregular flicker.
    static func buzz() -> [Float] {
        var rng = RNG(41)
        return loop(seconds: 6, fade: 0.1, peak: 0.6) { n in
            var flicker = [Double](repeating: 1, count: n)
            var clicks = [Double](repeating: 0, count: n)
            for _ in 0..<5 {
                let s = Int(rng.range(0.2, 5.6) * sampleRate)
                let len = Int(rng.range(0.05, 0.25) * sampleRate)
                for i in s..<min(n, s + len) { flicker[i] = 0.15 }
                add(&clicks, at: s, burst(&rng, seconds: 0.01, decay: 0.002,
                                          filters: [Biquad(.highpass, freq: 3000)], amp: 0.6))
            }
            var smoothed = 1.0
            let raw: [Double] = (0..<n).map { i in
                let t = Double(i) / sampleRate
                let ph = (t * 120).truncatingRemainder(dividingBy: 1)
                smoothed += (flicker[i] - smoothed) * 0.004
                return (ph * 2 - 1) * smoothed
            }
            let shaped = filtered(raw, [Biquad(.lowpass, freq: 2200), Biquad(.highpass, freq: 90)])
            return shaped.enumerated().map { i, v in v + clicks[i] }
        }
    }

    /// Draft down the stairwell: gusting filtered noise with a faint whistle.
    static func wind() -> [Float] {
        var rng = RNG(53)
        return loop(seconds: 12, fade: 1.5, peak: 0.75) { n in
            let body = filtered(noise(n, &rng), [Biquad(.lowpass, freq: 650), Biquad(.highpass, freq: 70)])
            let whistle = filtered(noise(n, &rng), [Biquad(.bandpass, freq: 1150, q: 9)])
            return (0..<n).map { i in
                let t = Double(i) / sampleRate
                let gust = 0.55 + 0.3 * sin(2 * Double.pi * t / 12) + 0.15 * sin(2 * Double.pi * t * 3 / 12 + 1)
                return body[i] * gust + whistle[i] * 2.5 * gust * gust
            }
        }
    }

    /// Outside at night: crickets, leaves, far-off rumble.
    static func outdoor() -> [Float] {
        var rng = RNG(67)
        return loop(seconds: 10, fade: 1.0, peak: 0.6) { n in
            var x = filtered(noise(n, &rng), [Biquad(.lowpass, freq: 180)]).map { $0 * 0.9 }
            let leaves = filtered(noise(n, &rng), [Biquad(.bandpass, freq: 3200, q: 0.8)])
            for i in 0..<n {
                let t = Double(i) / sampleRate
                x[i] += leaves[i] * 0.25 * (0.5 + 0.5 * sin(2 * Double.pi * t * 0.3))
            }
            for (freq, gap, amp) in [(4600.0, 0.75, 0.35), (5150.0, 1.1, 0.2)] {
                var t = rng.range(0, 0.4)
                while t < Double(n) / sampleRate - 0.2 {
                    for p in 0..<3 {
                        add(&x, at: samples(t + Double(p) * 0.022), ping(freq: freq, decay: 0.006, seconds: 0.02, amp: amp))
                    }
                    t += gap + rng.range(-0.15, 0.25)
                }
            }
            return x
        }
    }

    /// Soft pink-ish hush heard close to a wall. Different seeds decorrelate the probes.
    static func wallPresence(seed: UInt64) -> [Float] {
        var rng = RNG(100 + seed)
        return loop(seconds: 3, fade: 0.5, peak: 0.6) { n in
            filtered(noise(n, &rng), [Biquad(.lowpass, freq: 1400), Biquad(.lowpass, freq: 2400), Biquad(.highpass, freq: 180)])
        }
    }

    // MARK: - One-shots

    static func bump() -> [Float] {
        var rng = RNG(71)
        var x = [Double](repeating: 0, count: samples(0.35))
        add(&x, at: 0, ping(freq: 85, decay: 0.06, seconds: 0.35, amp: 1.0))
        add(&x, at: 0, ping(freq: 170, decay: 0.035, seconds: 0.25, amp: 0.5))
        add(&x, at: 0, burst(&rng, seconds: 0.08, decay: 0.012, filters: [Biquad(.lowpass, freq: 1200)], amp: 0.9))
        add(&x, at: 0, burst(&rng, seconds: 0.03, decay: 0.005, filters: [Biquad(.highpass, freq: 2500)], amp: 0.25))
        normalize(&x, peak: 0.9)
        return toFloat(x)
    }

    /// Hand brushing along a wall.
    static func brush() -> [Float] {
        var rng = RNG(73)
        let n = samples(0.32)
        let raw = noise(n, &rng).enumerated().map { i, v -> Double in
            let t = Double(i) / sampleRate
            let env = min(1, t / 0.04) * max(0, min(1, (0.32 - t) / 0.12))
            let grain = 0.7 + 0.3 * sin(2 * Double.pi * 37 * t + rng.range(0, 0.3))
            return v * env * grain
        }
        var x = filtered(raw, [Biquad(.bandpass, freq: 2100, q: 1.1)])
        normalize(&x, peak: 0.7)
        return toFloat(x)
    }

    /// Shoe scuff while turning on the spot.
    static func pivot() -> [Float] {
        var rng = RNG(79)
        var x = burst(&rng, seconds: 0.16, decay: 0.05, attack: 0.02,
                      filters: [Biquad(.lowpass, freq: 1600), Biquad(.highpass, freq: 200)])
        normalize(&x, peak: 0.6)
        return toFloat(x)
    }

    /// Soft change of air when passing through an opening.
    static func threshold() -> [Float] {
        var rng = RNG(83)
        let n = samples(0.5)
        let raw = noise(n, &rng).enumerated().map { i, v -> Double in
            let t = Double(i) / sampleRate
            return v * sin(Double.pi * t / 0.5)
        }
        var x = filtered(raw, [Biquad(.lowpass, freq: 320), Biquad(.lowpass, freq: 500)])
        normalize(&x, peak: 0.6)
        return toFloat(x)
    }

    static func click(freq: Double) -> [Float] {
        var x = ping(freq: freq, decay: 0.003, seconds: 0.02, amp: 1)
        normalize(&x, peak: 0.5)
        return toFloat(x)
    }

    /// Door creaking open, then a warm resolving chord as outside air rushes in.
    static func completion() -> [Float] {
        var rng = RNG(89)
        let n = samples(7.5)
        var x = [Double](repeating: 0, count: n)
        // Creak.
        let cLen = samples(1.3)
        var phase = 0.0
        var creak = [Double](repeating: 0, count: cLen)
        for i in 0..<cLen {
            let t = Double(i) / sampleRate
            let f = 170 + 90 * t + 12 * sin(2 * Double.pi * 9 * t)
            phase += 2 * Double.pi * f / sampleRate
            let ph = (phase / (2 * Double.pi)).truncatingRemainder(dividingBy: 1)
            creak[i] = (ph * 2 - 1) * min(1, t / 0.1) * max(0, 1 - t / 1.3)
        }
        add(&x, at: 0, filtered(creak, [Biquad(.bandpass, freq: 900, q: 3)]), gain: 0.9)
        // Rush of air.
        let air = noise(n, &rng)
        let airF = filtered(air, [Biquad(.lowpass, freq: 1200)])
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let env = t < 0.8 ? 0 : min(1, (t - 0.8) / 1.0) * max(0, 1 - (t - 1.8) / 5.5)
            x[i] += airF[i] * env * 0.5
        }
        // Chord: A major, slow swell.
        let notes = [110.0, 164.81, 220.0, 277.18, 329.63, 440.0]
        for (k, f) in notes.enumerated() {
            for i in samples(1.0)..<n {
                let t = Double(i) / sampleRate - 1.0
                let env = min(1, t / (1.5 + 0.1 * Double(k))) * max(0, min(1, (6.3 - t) / 2.5))
                let trem = 1 + 0.06 * sin(2 * Double.pi * (4.5 + Double(k) * 0.3) * t)
                x[i] += sin(2 * Double.pi * f * t) * env * trem * (0.22 - 0.02 * Double(k))
            }
        }
        normalize(&x, peak: 0.85)
        return toFloat(x)
    }

    // MARK: - Footsteps

    static func footstep(_ s: Surface, variant v: Int) -> [Float] {
        var rng = RNG(1000 + UInt64(v) * 31 + UInt64(Surface.allCases.firstIndex(of: s)!) * 977)
        let pitch = 1 + rng.range(-0.07, 0.07)
        var x = [Double](repeating: 0, count: samples(0.45))
        switch s {
        case .wetConcrete:
            add(&x, at: 0, burst(&rng, seconds: 0.12, decay: 0.022, filters: [Biquad(.lowpass, freq: 1700 * pitch)]))
            add(&x, at: 0, ping(freq: 95 * pitch, decay: 0.03, seconds: 0.12, amp: 0.45))
            add(&x, at: samples(0.012), burst(&rng, seconds: 0.25, decay: 0.07, attack: 0.01,
                                               filters: [Biquad(.bandpass, freq: 3600 * pitch, q: 0.8)], amp: 0.55))
            for _ in 0..<3 {
                add(&x, at: samples(rng.range(0.03, 0.14)),
                    ping(freq: rng.range(1800, 3000), decay: 0.006, seconds: 0.03, amp: 0.12, glide: 4))
            }
        case .dryConcrete:
            add(&x, at: 0, burst(&rng, seconds: 0.1, decay: 0.018, filters: [Biquad(.lowpass, freq: 2200 * pitch)]))
            add(&x, at: 0, ping(freq: 110 * pitch, decay: 0.025, seconds: 0.1, amp: 0.4))
            add(&x, at: samples(0.05), burst(&rng, seconds: 0.1, decay: 0.03, attack: 0.01,
                                              filters: [Biquad(.bandpass, freq: 1800, q: 1)], amp: 0.15))
        case .woodBoards:
            add(&x, at: 0, ping(freq: 128 * pitch, decay: 0.07, seconds: 0.3, amp: 0.8))
            add(&x, at: 0, ping(freq: 260 * pitch, decay: 0.04, seconds: 0.2, amp: 0.35))
            add(&x, at: 0, burst(&rng, seconds: 0.08, decay: 0.015, filters: [Biquad(.lowpass, freq: 900 * pitch)], amp: 0.7))
            if v % 2 == 1 {
                // Board creak.
                let len = samples(0.18)
                var ph = 0.0
                var creak = [Double](repeating: 0, count: len)
                let f0 = rng.range(380, 520)
                for i in 0..<len {
                    let t = Double(i) / sampleRate
                    ph += 2 * Double.pi * (f0 - 120 * t) / sampleRate
                    creak[i] = (ph / (2 * Double.pi)).truncatingRemainder(dividingBy: 1) * 2 - 1
                    creak[i] *= sin(Double.pi * t / 0.18)
                }
                add(&x, at: samples(0.06), filtered(creak, [Biquad(.bandpass, freq: 1100, q: 4)]), gain: 0.25)
            }
        case .metalGrate:
            add(&x, at: 0, burst(&rng, seconds: 0.05, decay: 0.008, filters: [Biquad(.highpass, freq: 1500)], amp: 0.6))
            for (f, d, a) in [(430.0, 0.12, 0.35), (1180.0, 0.09, 0.3), (2050.0, 0.06, 0.25), (3120.0, 0.04, 0.2)] {
                add(&x, at: 0, ping(freq: f * pitch, decay: d, seconds: 0.4, amp: a))
            }
            add(&x, at: samples(0.028), burst(&rng, seconds: 0.04, decay: 0.006, filters: [Biquad(.highpass, freq: 2000)], amp: 0.3))
            add(&x, at: 0, ping(freq: 90, decay: 0.03, seconds: 0.1, amp: 0.4))
        case .grit:
            add(&x, at: 0, burst(&rng, seconds: 0.08, decay: 0.02, filters: [Biquad(.lowpass, freq: 2600 * pitch)], amp: 0.7))
            for _ in 0..<45 {
                let t = rng.range(0.0, 0.15)
                add(&x, at: samples(t), burst(&rng, seconds: 0.004, decay: 0.0008,
                                              filters: [Biquad(.highpass, freq: 2500)], amp: rng.range(0.2, 0.6) * exp(-t / 0.08)))
            }
        case .stoneStairs:
            add(&x, at: 0, burst(&rng, seconds: 0.03, decay: 0.004, filters: [Biquad(.highpass, freq: 2200)], amp: 0.8))
            add(&x, at: 0, ping(freq: 150 * pitch, decay: 0.035, seconds: 0.15, amp: 0.6))
            add(&x, at: samples(0.004), burst(&rng, seconds: 0.1, decay: 0.02, filters: [Biquad(.lowpass, freq: 3000)], amp: 0.4))
        case .outside:
            for _ in 0..<30 {
                let t = rng.range(0.0, 0.2)
                add(&x, at: samples(t), burst(&rng, seconds: 0.006, decay: 0.0015,
                                              filters: [Biquad(.bandpass, freq: 1800, q: 0.7)], amp: rng.range(0.2, 0.5)))
            }
            add(&x, at: 0, burst(&rng, seconds: 0.1, decay: 0.03, filters: [Biquad(.lowpass, freq: 700)], amp: 0.5))
        }
        normalize(&x, peak: 0.85)
        return toFloat(x)
    }
}
