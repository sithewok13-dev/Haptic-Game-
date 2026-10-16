import CoreHaptics
import UIKit

/// The whole haptic vocabulary: a few brief, distinct patterns.
/// Phone vibration cannot say left or right, so direction is left to audio.
enum HapticKind {
    /// Walked into a wall and bounced back: a heavy knock (repeats while you keep walking into it).
    case bump
    /// Touching a wall while sliding along it: a light tap, once per step.
    case brush
    /// Passed through an opening into a new space: two soft, dull pulses.
    case threshold
    /// Facing lines up with the walls: a tiny crisp tick.
    case aligned
    /// Reached the exit: a slow swell.
    case completion
}

final class HapticsPlayer {
    var enabled = true
    /// Overall comfort scale for intensities.
    var intensityScale: Float = 1.0

    let supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    private var engine: CHHapticEngine?
    private var engineRunning = false
    private var patterns: [HapticKind: CHHapticPattern] = [:]
    private let impact = UIImpactFeedbackGenerator(style: .heavy)
    private let lightImpact = UIImpactFeedbackGenerator(style: .light)

    init() {
        guard supportsHaptics else { return }
        do {
            let e = try CHHapticEngine()
            e.playsHapticsOnly = true
            e.isAutoShutdownEnabled = true
            e.stoppedHandler = { [weak self] _ in self?.engineRunning = false }
            e.resetHandler = { [weak self] in
                self?.engineRunning = false
                self?.startIfNeeded()
            }
            engine = e
            buildPatterns()
        } catch {
            NSLog("CellarEscape: haptics unavailable: \(error)")
        }
    }

    private func event(_ time: TimeInterval, intensity: Float, sharpness: Float,
                       duration: TimeInterval? = nil) -> CHHapticEvent {
        let params = [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: min(1, intensity * intensityScale)),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
        ]
        if let d = duration {
            return CHHapticEvent(eventType: .hapticContinuous, parameters: params, relativeTime: time, duration: d)
        }
        return CHHapticEvent(eventType: .hapticTransient, parameters: params, relativeTime: time)
    }

    private func buildPatterns() {
        do {
            // A solid knock you can't miss: sharp hit, a short heavy body, and a small rebound.
            patterns[.bump] = try CHHapticPattern(events: [
                event(0, intensity: 1.0, sharpness: 0.55),
                event(0.004, intensity: 0.8, sharpness: 0.2, duration: 0.12),
                event(0.09, intensity: 0.5, sharpness: 0.4),
            ], parameters: [])
            patterns[.brush] = try CHHapticPattern(events: [
                event(0, intensity: 0.55, sharpness: 0.5),
            ], parameters: [])
            patterns[.threshold] = try CHHapticPattern(events: [
                event(0, intensity: 0.45, sharpness: 0.1),
                event(0.11, intensity: 0.35, sharpness: 0.1),
            ], parameters: [])
            patterns[.aligned] = try CHHapticPattern(events: [
                event(0, intensity: 0.3, sharpness: 0.9),
            ], parameters: [])
            let swell = event(0, intensity: 0.7, sharpness: 0.25, duration: 1.6)
            let curve = CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: [
                .init(relativeTime: 0, value: 0.1),
                .init(relativeTime: 0.7, value: 1.0),
                .init(relativeTime: 1.6, value: 0.0),
            ], relativeTime: 0)
            patterns[.completion] = try CHHapticPattern(events: [
                swell,
                event(0.25, intensity: 0.4, sharpness: 0.3),
                event(0.55, intensity: 0.6, sharpness: 0.3),
                event(0.85, intensity: 0.8, sharpness: 0.3),
            ], parameterCurves: [curve])
        } catch {
            NSLog("CellarEscape: haptic pattern error: \(error)")
        }
    }

    func startIfNeeded() {
        guard let e = engine, !engineRunning else { return }
        do {
            try e.start()
            engineRunning = true
        } catch {
            NSLog("CellarEscape: haptic engine start failed: \(error)")
        }
    }

    func stop() {
        engine?.stop(completionHandler: nil)
        engineRunning = false
    }

    /// Returns false when nothing could be felt (disabled or unsupported), so the
    /// caller can add an audible substitute where one is needed.
    @discardableResult
    func play(_ kind: HapticKind) -> Bool {
        guard enabled else { return false }
        if let e = engine, let pattern = patterns[kind] {
            startIfNeeded()
            do {
                try e.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
                return true
            } catch {
                engineRunning = false
            }
        }
        // Fallback for devices without Core Haptics support.
        switch kind {
        case .bump, .completion: impact.impactOccurred(intensity: CGFloat(intensityScale))
        case .brush, .threshold, .aligned: lightImpact.impactOccurred(intensity: CGFloat(intensityScale * 0.6))
        }
        return supportsHaptics
    }
}
