import Foundation

/// Everything the presentation layers (audio, haptics, speech) need to react to.
public enum Cue: Equatable {
    case sim(SimEvent)
    case speak(String, interrupt: Bool)
    case stopSpeech
    /// Fade the world's sound in (true) or out (false).
    case worldAudio(active: Bool)
    case enteredRoom(Int)
    case completion
    case menuTick
    case settingsChanged(GameSettings)
    /// The world was reset to the start (fresh room acoustics, no position jump mid-play).
    case restarted
}

public enum PracticeStep: Int, Equatable {
    case walk, stop, turnToSound, approach
}

public enum Phase: Equatable {
    case practice(PracticeStep)
    case exploring
    case paused
    case completed
}

public enum PauseReason: Equatable {
    case player, background, interruption, headphonesRemoved
}

public enum MenuItem: Equatable {
    case resume, controls, haptics, wallSense, turnSpeed, skipPractice, restart, developerMap
}

public enum Script {
    public static let controls = "Hold one finger still to walk. Lift it to stop and listen. Drag left or right to turn. "
        + "Swipe two fingers left or right to turn and face along the walls. Swipe two fingers down to turn around. "
        + "Tap two fingers to sense your surroundings. Hold two fingers to pause."
    public static let intro = "You wake on a cold, wet floor, in complete darkness. "
        + "Headphones help: sounds keep their place around you as you turn. "
        + "Hold one finger still on the screen to walk forward."
    public static let practiceStop = "Good. Lift your finger to stop and listen."
    public static let practiceTurn = "Drag a finger left or right to turn on the spot. "
        + "Somewhere in this room, water is dripping. Turn until it is straight ahead of you."
    public static let practiceApproach = "That's it. Now walk toward the dripping, and stop when you are close."
    public static let practiceDone = "You found the pipe. If you walk into a wall you'll feel a bump; nothing here can hurt you. "
        + "Swipe two fingers left or right to turn and face along the walls, or down to turn around. "
        + "Tap two fingers to sense your surroundings. Hold two fingers to pause. Find the way out."
    public static let practiceLeft = "Tap two fingers to sense your surroundings. Hold two fingers to pause."
    public static let completion = "Cold night air. You're outside. You found the way out. "
        + "Double-tap to explore the basement again."
    public static let pausedHelp = "Swipe left or right for options, double-tap to choose. Hold two fingers to resume."
}

/// Session state machine: practice, exploring, paused, completed.
/// Owns the simulation and the gesture interpreter; emits cues for presentation.
public final class GameSession {
    public let sim: Simulation
    public let input = InputInterpreter()
    public private(set) var phase: Phase
    public private(set) var settings: GameSettings
    public private(set) var pauseReason: PauseReason?

    private var resumePhase: Phase = .exploring
    private var menuIndex = 0
    private var restartArmedUntil = -1.0
    private var clock = 0.0
    private var promptTime = 0.0
    private var promptRepeats = 0
    private var turnedDuringStep = 0.0
    private var delayedSpeech: (time: Double, text: String)?

    public init(world: World, settings: GameSettings = GameSettings()) {
        sim = Simulation(world: world)
        self.settings = settings
        phase = settings.practiceDone ? .exploring : .practice(.walk)
    }

    /// The landmark used in practice: the first named sound in the start room.
    public var practiceSource: SoundSource? {
        sim.world.sources.first { $0.room == sim.world.startRoom && $0.definition.landmark != nil }
    }

    /// Opening speech. Call once the audio is running.
    public func begin() -> [Cue] {
        promptTime = clock
        promptRepeats = 0
        if case .practice = phase {
            return [.worldAudio(active: true), .enteredRoom(sim.room), .speak(Script.intro, interrupt: true)]
        }
        return [.worldAudio(active: true), .enteredRoom(sim.room),
                .speak("You wake in darkness. Tap two fingers to sense your surroundings. Hold two fingers to pause.", interrupt: true)]
    }

    // MARK: - Input

    public func handleTouches(_ samples: [TouchSample], time: Double) -> [Cue] {
        input.handle(samples, time: time).flatMap { handle($0) }
    }

    public func handle(_ g: Gesture) -> [Cue] {
        switch phase {
        case .practice, .exploring:
            return handleInWorld(g)
        case .paused:
            return handleInMenu(g)
        case .completed:
            switch g {
            case .doubleTap: return restart(withPractice: false)
            case .twoFingerTap: return [.speak(Script.completion, interrupt: true)]
            case .twoFingerHold: return pause(.player)
            default: return []
            }
        }
    }

    private func handleInWorld(_ g: Gesture) -> [Cue] {
        switch g {
        case .walkBegan:
            sim.setWalking(true)
        case .walkEnded:
            sim.setWalking(false)
        case .turn(let points):
            let deg = points * settings.turnSpeed.degreesPerPoint
            turnedDuringStep += abs(deg)
            sim.turn(byDegrees: deg)
        case .twoFingerSwipe(let dir):
            switch dir {
            case .left: sim.snapTurn(direction: -1)
            case .right: sim.snapTurn(direction: 1)
            case .down: sim.turnAround()
            case .up: break
            }
            turnedDuringStep += 90
        case .twoFingerTap:
            return [.speak(Orientation.describe(sim: sim), interrupt: true)]
        case .twoFingerHold:
            return pause(.player)
        default:
            break
        }
        return []
    }

    // MARK: - Pause menu

    public var menuItems: [MenuItem] {
        var items: [MenuItem] = [.resume, .controls, .haptics, .wallSense, .turnSpeed]
        if case .practice = resumePhase { items.append(.skipPractice) }
        items += [.restart, .developerMap]
        return items
    }

    public func label(_ item: MenuItem) -> String {
        switch item {
        case .resume: return "Resume"
        case .controls: return "Hear the controls"
        case .haptics: return "Vibration: " + (settings.haptics ? "on" : "off")
        case .wallSense: return "Wall sense sound: " + (settings.wallSense ? "on" : "off")
        case .turnSpeed: return "Turning speed: " + settings.turnSpeed.rawValue
        case .skipPractice: return "Skip practice"
        case .restart: return "Restart from the beginning"
        case .developerMap: return "Developer map: " + (settings.developerMap ? "on" : "off")
        }
    }

    public var currentMenuItem: MenuItem { menuItems[min(menuIndex, menuItems.count - 1)] }

    public func pause(_ reason: PauseReason) -> [Cue] {
        var cues = input.reset().flatMap { handleInWorld($0) }
        sim.setWalking(false)
        if phase == .paused {
            // Already paused: keep the original reason unless headphones were just removed.
            if reason == .headphonesRemoved { cues.append(.speak("Headphones disconnected.", interrupt: true)) }
            return cues
        }
        resumePhase = phase
        phase = .paused
        pauseReason = reason
        menuIndex = 0
        restartArmedUntil = -1
        delayedSpeech = nil
        let prefix = reason == .headphonesRemoved ? "Headphones disconnected. Paused. " : "Paused. "
        cues += [.worldAudio(active: false), .speak(prefix + Script.pausedHelp, interrupt: true)]
        return cues
    }

    /// Spoken when returning to the foreground while paused.
    public func pausedReminder() -> [Cue] {
        guard phase == .paused else { return [] }
        return [.speak("Paused. Hold two fingers to resume.", interrupt: true)]
    }

    public func resume() -> [Cue] {
        guard phase == .paused else { return [] }
        phase = resumePhase
        pauseReason = nil
        promptTime = clock
        _ = input.reset()
        return [.worldAudio(active: true), .speak("Resumed.", interrupt: true)]
    }

    private func handleInMenu(_ g: Gesture) -> [Cue] {
        let items = menuItems
        switch g {
        case .swipe(.right), .twoFingerSwipe(.right):
            menuIndex = (menuIndex + 1) % items.count
            restartArmedUntil = -1
            return [.menuTick, .speak(label(currentMenuItem), interrupt: true)]
        case .swipe(.left), .twoFingerSwipe(.left):
            menuIndex = (menuIndex - 1 + items.count) % items.count
            restartArmedUntil = -1
            return [.menuTick, .speak(label(currentMenuItem), interrupt: true)]
        case .doubleTap:
            return activate(currentMenuItem)
        case .twoFingerTap:
            return [.speak(label(currentMenuItem) + ". " + Script.pausedHelp, interrupt: true)]
        case .twoFingerHold:
            return resume()
        default:
            return []
        }
    }

    private func activate(_ item: MenuItem) -> [Cue] {
        switch item {
        case .resume:
            return resume()
        case .controls:
            return [.speak(Script.controls, interrupt: true)]
        case .haptics:
            settings.haptics.toggle()
            return [.settingsChanged(settings), .speak(label(item), interrupt: true)]
        case .wallSense:
            settings.wallSense.toggle()
            return [.settingsChanged(settings), .speak(label(item), interrupt: true)]
        case .turnSpeed:
            let all = TurnSpeed.allCases
            settings.turnSpeed = all[(all.firstIndex(of: settings.turnSpeed)! + 1) % all.count]
            return [.settingsChanged(settings), .speak(label(item), interrupt: true)]
        case .developerMap:
            settings.developerMap.toggle()
            return [.settingsChanged(settings), .speak(label(item), interrupt: true)]
        case .skipPractice:
            settings.practiceDone = true
            resumePhase = .exploring
            menuIndex = 0
            return [.settingsChanged(settings)] + resume() + [.speak("Practice skipped. " + Script.practiceLeft, interrupt: false)]
        case .restart:
            if clock <= restartArmedUntil {
                return restart(withPractice: !settings.practiceDone)
            }
            restartArmedUntil = clock + 4
            return [.speak("Double-tap again to restart from the beginning.", interrupt: true)]
        }
    }

    public func restart(withPractice: Bool) -> [Cue] {
        _ = input.reset()
        sim.reset()
        phase = withPractice ? .practice(.walk) : .exploring
        pauseReason = nil
        delayedSpeech = nil
        turnedDuringStep = 0
        promptTime = clock
        promptRepeats = 0
        let line = withPractice ? Script.intro : "You wake again in the dark, on the wet floor."
        return [.restarted, .worldAudio(active: true), .enteredRoom(sim.room), .speak(line, interrupt: true)]
    }

    // MARK: - Time

    /// Advance one frame. `now` is a monotonic clock in seconds (for gesture timers).
    public func update(dt: Double, now: Double) -> [Cue] {
        var cues = input.tick(time: now).flatMap { handle($0) }
        let step = max(0, min(dt, 0.05))
        clock += step

        if let d = delayedSpeech, clock >= d.time {
            delayedSpeech = nil
            cues.append(.speak(d.text, interrupt: false))
        }

        switch phase {
        case .practice, .exploring:
            for e in sim.update(dt: step) {
                cues.append(.sim(e))
                switch e {
                case .threshold(_, let to):
                    cues.append(.enteredRoom(to))
                case .reachedExit:
                    _ = input.reset()
                    phase = .completed
                    settings.practiceDone = true
                    cues += [.settingsChanged(settings), .completion, .stopSpeech]
                    delayedSpeech = (clock + 4.5, Script.completion)
                default:
                    break
                }
            }
            if case .practice(let step) = phase { cues += advancePractice(step) }
        case .paused, .completed:
            break
        }
        return cues
    }

    private func advancePractice(_ step: PracticeStep) -> [Cue] {
        if sim.room != sim.world.startRoom {
            settings.practiceDone = true
            phase = .exploring
            return [.settingsChanged(settings), .speak(Script.practiceLeft, interrupt: false)]
        }
        var next: PracticeStep?
        var line = ""
        switch step {
        case .walk:
            if sim.isWalking && sim.distanceWalked >= 1.2 { next = .stop; line = Script.practiceStop }
        case .stop:
            if !sim.isWalking { next = .turnToSound; line = Script.practiceTurn }
        case .turnToSound:
            if let src = practiceSource {
                let lp = ListenerPoint(world: src.position, listener: sim.position, heading: sim.heading)
                if abs(Heading.degrees(lp.bearing)) < 20 && turnedDuringStep >= 15 && !sim.isSnapTurning {
                    next = .approach
                    line = Script.practiceApproach
                }
            } else {
                next = .approach
            }
        case .approach:
            let close = practiceSource.map { $0.position.distance(to: sim.position) < 1.4 } ?? true
            if close {
                settings.practiceDone = true
                phase = .exploring
                return [.settingsChanged(settings), .speak(Script.practiceDone, interrupt: true)]
            }
        }
        if let n = next {
            phase = .practice(n)
            turnedDuringStep = 0
            promptTime = clock
            promptRepeats = 0
            return [.speak(line, interrupt: true)]
        }
        // Repeat the current prompt if the player seems stuck.
        if clock - promptTime > 25 && promptRepeats < 2 && !sim.isWalking {
            promptTime = clock
            promptRepeats += 1
            let text: String
            switch step {
            case .walk: text = "Hold one finger still on the screen to walk forward."
            case .stop: text = Script.practiceStop
            case .turnToSound: text = Script.practiceTurn
            case .approach: text = Script.practiceApproach
            }
            return [.speak(text, interrupt: false)]
        }
        return []
    }

    public func applySettings(_ s: GameSettings) {
        settings = s
    }
}
