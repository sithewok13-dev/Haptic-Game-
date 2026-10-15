import Foundation
@testable import CellarCore

enum Fixtures {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func basementDefinition() throws -> WorldDefinition {
        try WorldDefinition.load(contentsOf: repoRoot.appendingPathComponent("Content/basement.json"))
    }

    static func basement() throws -> World {
        try World(basementDefinition())
    }
}

/// Runs a session for `seconds` of simulated time at 60 fps, feeding optional gestures each frame.
@discardableResult
func run(_ session: GameSession, seconds: Double, clock: inout Double,
         gestures: ((Double) -> [Gesture])? = nil) -> [Cue] {
    let dt = 1.0 / 60
    var cues: [Cue] = []
    var t = 0.0
    while t < seconds {
        if let g = gestures?(dt) {
            for x in g { cues += session.handle(x) }
        }
        clock += dt
        cues += session.update(dt: dt, now: clock)
        t += dt
    }
    return cues
}

extension Array where Element == Cue {
    var simEvents: [SimEvent] {
        compactMap { if case .sim(let e) = $0 { return e } else { return nil } }
    }
    var spoken: [String] {
        compactMap { if case .speak(let s, _) = $0 { return s } else { return nil } }
    }
}
