import CellarCore
import Foundation

// Offline listening preview: the autopilot plays the basement through the real
// CellarCore session, and the result is mixed to a stereo WAV.
// This uses simple panning with a muffled "behind" cue and a basic reverb, NOT
// the HRTF rendering the iPhone app uses, so it is a rough guide to the sound
// design and pacing only.
//
// Usage: swift run CellarPreview [repoRoot] [out.wav]

let args = CommandLine.arguments
let root = URL(fileURLWithPath: args.count > 1 ? args[1] : FileManager.default.currentDirectoryPath)
let outPath = args.count > 2 ? args[2] : "preview.wav"

let world = try World(WorldDefinition.load(contentsOf: root.appendingPathComponent("Content/basement.json")))
var settings = GameSettings()
settings.practiceDone = true
let session = GameSession(world: world, settings: settings)
let scene = AudioScene(world: world)
let pilot = Autopilot(session: session, tour: ["ventRoom"])

let sampleRate = SoundSynth.sampleRate
let fps = 60.0
let samplesPerFrame = Int(sampleRate / fps)

final class Voice {
    let samples: [Float]
    var index: Int
    let looping: Bool
    var gainL: Float = 0, gainR: Float = 0
    var lp: Float = 0, lpR: Float = 0
    var cutoffCoeff: Float = 1
    var reverbSend: Float = 0

    init(_ samples: [Float], looping: Bool, offset: Int = 0) {
        self.samples = samples
        self.looping = looping
        index = samples.isEmpty ? 0 : offset % samples.count
    }

    var finished: Bool { !looping && index >= samples.count }

    func set(point: ListenerPoint, gain: Double, muffle: Double, reverb: Double) {
        let az = point.bearing
        let x = sin(az)
        var g = gain
        var m = muffle
        if cos(az) < 0 {  // behind: a little quieter and duller
            g *= 0.8
            m = min(1, m + 0.25 * -cos(az))
        }
        gainL = Float(g * cos((x + 1) * Double.pi / 4))
        gainR = Float(g * sin((x + 1) * Double.pi / 4))
        let cutoff = 9000 * pow(600.0 / 9000, m)
        cutoffCoeff = Float(1 - exp(-2 * Double.pi * cutoff / sampleRate))
        reverbSend = Float(reverb)
    }

    func render(into l: inout [Float], _ r: inout [Float], _ wet: inout [Float], count: Int) {
        for i in 0..<count {
            if index >= samples.count {
                if looping { index = 0 } else { return }
            }
            let s = samples[index]
            index += 1
            lp += (s - lp) * cutoffCoeff
            l[i] += lp * gainL
            r[i] += lp * gainR
            wet[i] += lp * (gainL + gainR) * 0.5 * reverbSend
        }
    }
}

/// Small comb/allpass reverb, enough to hear rooms differ.
struct Reverb {
    var combs: [[Float]]
    var pos: [Int]
    var feedback: Float = 0.78
    var level: Float = 0.3

    init() {
        let lengths = [1116, 1188, 1277, 1356, 1422, 1491]
        combs = lengths.map { [Float](repeating: 0, count: $0) }
        pos = Array(repeating: 0, count: lengths.count)
    }

    mutating func set(_ a: Acoustics) {
        switch a {
        case .smallRoom: feedback = 0.62; level = 0.22
        case .mediumRoom: feedback = 0.74; level = 0.3
        case .largeRoom: feedback = 0.8; level = 0.32
        case .corridor: feedback = 0.7; level = 0.28
        case .stairwell: feedback = 0.86; level = 0.42
        }
    }

    mutating func process(_ x: Float) -> (Float, Float) {
        var l: Float = 0, r: Float = 0
        for c in 0..<combs.count {
            let y = combs[c][pos[c]]
            combs[c][pos[c]] = x + y * feedback
            pos[c] = (pos[c] + 1) % combs[c].count
            if c % 2 == 0 { l += y } else { r += y }
        }
        return (l * level / 3, r * level / 3)
    }
}

var sourceVoices: [Voice] = world.sources.enumerated().map { i, s in
    Voice(SoundSynth.render(s.definition.sound), looping: true, offset: i * 9973)
}
var probeVoices: [Voice] = (0..<AudioScene.probeAngles.count).map { Voice(SoundSynth.render("wallPresence.\($0)"), looping: true) }
var oneShots: [Voice] = []
var cache: [String: [Float]] = [:]
func sound(_ id: String) -> [Float] {
    if let s = cache[id] { return s }
    let s = SoundSynth.render(id)
    cache[id] = s
    return s
}

func playOneShot(_ id: String, at p: ListenerPoint, gain: Double, reverb: Double = 0.3) {
    let v = Voice(sound(id), looping: false)
    v.set(point: p, gain: gain, muffle: 0, reverb: reverb)
    oneShots.append(v)
}

var reverb = Reverb()
var outL: [Float] = []
var outR: [Float] = []
var variant = 0
var log: [String] = []

func handle(_ cues: [Cue], time: Double) {
    let sim = session.sim
    for c in cues {
        switch c {
        case .sim(let e):
            switch e {
            case .footstep(let surface, _, let foot, _, let soft):
                variant = (variant + 1) % SoundSynth.footstepVariants
                playOneShot(SoundSynth.footstepID(surface, variant),
                            at: ListenerPoint(right: foot == 0 ? -0.14 : 0.14, forward: 0.15), gain: soft ? 0.25 : 0.5)
            case .wallBump(let p):
                playOneShot("bump", at: ListenerPoint(world: p, listener: sim.position, heading: sim.heading), gain: 0.85)
                log.append(String(format: "%6.1fs  bump", time))
            case .wallContactBegan(let p), .wallBrush(let p):
                playOneShot("brush", at: ListenerPoint(world: p, listener: sim.position, heading: sim.heading), gain: 0.3)
            case .threshold(_, let to):
                playOneShot("threshold", at: ListenerPoint(right: 0, forward: 0.4), gain: 0.3)
                log.append(String(format: "%6.1fs  enter %@", time, world.rooms[to].id))
            case .pivot:
                playOneShot("pivot", at: ListenerPoint(right: 0, forward: 0.1), gain: 0.3)
            case .aligned:
                playOneShot("alignClick", at: ListenerPoint(right: 0, forward: 1), gain: 0.12, reverb: 0)
            case .reachedExit:
                log.append(String(format: "%6.1fs  reached the exit", time))
            }
        case .enteredRoom(let r):
            reverb.set(world.rooms[r].acoustics)
        case .completion:
            playOneShot("completion", at: ListenerPoint(right: 0, forward: 1.5), gain: 1)
        default:
            break
        }
    }
}

var now = 0.0
handle(session.begin(), time: 0)
var tail = 0.0
while tail < 7 && now < 240 {
    let dt = 1 / fps
    for g in pilot.step(dt: dt) { handle(session.handle(g), time: now) }
    now += dt
    handle(session.update(dt: dt, now: now), time: now)
    if session.phase == .completed { tail += dt }

    let sim = session.sim
    let mix = scene.update(listener: sim.position, heading: sim.heading, room: sim.room, dt: dt, wallSense: true)
    for (i, v) in mix.sources.enumerated() {
        sourceVoices[i].set(point: v.position, gain: v.gain, muffle: v.muffle, reverb: v.reverbBlend)
    }
    for (i, v) in mix.probes.enumerated() {
        probeVoices[i].set(point: v.position, gain: v.gain, muffle: v.muffle, reverb: v.reverbBlend)
    }

    var l = [Float](repeating: 0, count: samplesPerFrame)
    var r = [Float](repeating: 0, count: samplesPerFrame)
    var wet = [Float](repeating: 0, count: samplesPerFrame)
    for v in sourceVoices + probeVoices + oneShots { v.render(into: &l, &r, &wet, count: samplesPerFrame) }
    oneShots.removeAll { $0.finished }
    for i in 0..<samplesPerFrame {
        let (wl, wr) = reverb.process(wet[i])
        outL.append(l[i] + wl)
        outR.append(r[i] + wr)
    }
}

// Normalise and write 16-bit stereo WAV.
let peak = max(outL.map(abs).max() ?? 1, outR.map(abs).max() ?? 1, 1e-6)
let gain = min(1, 0.9 / peak)
var data = Data()
func le<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
let frames = outL.count
data.append(contentsOf: Array("RIFF".utf8)); le(UInt32(36 + frames * 4))
data.append(contentsOf: Array("WAVEfmt ".utf8)); le(UInt32(16)); le(UInt16(1)); le(UInt16(2))
le(UInt32(sampleRate)); le(UInt32(sampleRate * 4)); le(UInt16(4)); le(UInt16(16))
data.append(contentsOf: Array("data".utf8)); le(UInt32(frames * 4))
for i in 0..<frames {
    le(Int16(max(-1, min(1, outL[i] * gain)) * 32767))
    le(Int16(max(-1, min(1, outR[i] * gain)) * 32767))
}
try data.write(to: URL(fileURLWithPath: outPath))
print(log.joined(separator: "\n"))
print(String(format: "Wrote %@: %.1f s, completed=%@", outPath, Double(frames) / sampleRate, session.phase == .completed ? "yes" : "no"))
