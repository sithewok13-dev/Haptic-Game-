import Foundation

/// Everything the presentation layers (audio, haptics, speech) need to react to.
public enum Cue: Equatable {
    case sim(SimEvent)
    case speak(String, interrupt: Bool)
    case stopSpeech
    /// Fade the world's sound in (true) or out (false).
    case worldAudio(active: Bool)
    case enteredRoom(Int)
    /// Cane tap: `echo` is where the wall ahead was hit (nil = open space ahead), `distance` in metres.
    case caneTap(echo: Vec2?, distance: Double?)
    case completion
    case menuTick
    case settingsChanged(GameSettings)
    /// The world was reset to the start (fresh room acoustics, no position jump mid-play).
    case restarted
}

public enum PracticeStep: Int, Equatable {
    case walk, stop, turnToSound, approach, cane
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
    case resume, controls, haptics, wallSense, turnStep, speakDirection, announceRooms, skipPractice, restart, developerMap
}

public enum Script {
    public static let controls = "Hold one finger on the screen to walk. Lift it to stop. "
        + "Swipe left or right to turn. Swipe down to turn around. "
        + "Tap once to tap your cane and hear how far the wall ahead is. "
        + "Tap with two fingers to hear where you are. Hold two fingers to pause."
    public static let intro = "You wake on a cold, wet floor, in complete darkness. Wear headphones. "
        + "Hold one finger on the screen to walk forward."
    public static let practiceStop = "Good. Lift your finger to stop."
    public static let practiceTurn = "Swipe left or right to turn. Somewhere in this room, water is dripping. "
        + "Turn until the dripping is straight ahead of you."
    public static let practiceApproach = "That's it. Now hold to walk toward the dripping. Stop when you're close."
    public static let practiceCane = "You found the pipe. Now tap the screen once. That's your cane. "
        + "The echo tells you how far away the wall in front of you is. A quick echo means close. No echo means open space."
    public static let practiceDone = "Good. Swipe down to turn around. Tap with two fingers to hear where you are. "
        + "Hold two fingers to pause. Walls stop you safely; nothing here can hurt you. Find the way out."
    public static let practiceLeft = "Tap with two fingers to hear where you are. Hold two fingers to pause."
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
    private var caneTapped = false
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
                .speak("You wake in darkness. Tap with two fingers to hear where you are. Hold two fingers to pause.", interrupt: true)]
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
            // Fine turning: used by the autopilot and tests, not produced by touch input.
            let deg = points * GameSettings.degreesPerPoint
            turnedDuringStep += abs(deg)
            sim.turn(byDegrees: deg)
        case .swipe(let dir), .twoFingerSwipe(let dir):
            let target: Double
            switch dir {
            case .left: target = sim.snapTurn(direction: -1, step: Double(settings.turnStep))
            case .right: target = sim.snapTurn(direction: 1, step: Double(settings.turnStep))
            case .down: target = sim.turnAround(step: Double(settings.turnStep))
            case .up: return []
            }
            turnedDuringStep += Double(settings.turnStep)
            if settings.speakDirection {
                return [.speak(Orientation.compassWord(headingDegrees: target), interrupt: true)]
            }
        case .tap:
            return [caneTap()]
        case .twoFingerTap:
            return [.speak(Orientation.describe(sim: sim), interrupt: true)]
        case .twoFingerHold:
            return pause(.player)
        default:
            break
        }
        return []
    }

    public static let caneRange = 8.0

    private func caneTap() -> Cue {
        caneTapped = true
        let dir = Heading.forward(sim.heading)
        if let hit = sim.world.raycast(from: sim.position, direction: dir, maxDistance: GameSession.caneRange) {
            return .caneTap(echo: hit.point, distance: hit.distance)
        }
        return .caneTap(echo: nil, distance: nil)
    }

    // MARK: - Pause menu

    public var menuItems: [MenuItem] {
        var items: [MenuItem] = [.resume, .controls, .haptics, .wallSense, .turnStep, .speakDirection, .announceRooms]
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
        case .turnStep: return "Each turn: \(settings.turnStep) degrees"
        case .speakDirection: return "Say direction after turning: " + (settings.speakDirection ? "on" : "off")
        case .announceRooms: return "Say room names: " + (settings.announceRooms ? "on" : "off")
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
        case .turnStep:
            settings.turnStep = settings.turnStep == 45 ? 90 : 45
            return [.settingsChanged(settings), .speak(label(item), interrupt: true)]
        case .speakDirection:
            settings.speakDirection.toggle()
            return [.settingsChanged(settings), .speak(label(item), interrupt: true)]
        case .announceRooms:
            settings.announceRooms.toggle()
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
                    if settings.announceRooms {
                        cues.append(.speak(Orientation.roomName(sim.world.rooms[to], capitalized: true), interrupt: true))
                    }
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
                if abs(Heading.degrees(lp.bearing)) < 25 && turnedDuringStep >= 15 && !sim.isSnapTurning {
                    next = .approach
                    line = Script.practiceApproach
                }
            } else {
                next = .approach
            }
        case .approach:
            let close = practiceSource.map { $0.position.distance(to: sim.position) < 1.4 } ?? true
            if close && !sim.isWalking {
                next = .cane
                line = Script.practiceCane
                caneTapped = false
            }
        case .cane:
            if caneTapped {
                settings.practiceDone = true
                phase = .exploring
                return [.settingsChanged(settings), .speak(Script.practiceDone, interrupt: false)]
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
            case .walk: text = "Hold one finger on the screen to walk forward."
            case .stop: text = Script.practiceStop
            case .turnToSound: text = Script.practiceTurn
            case .approach: text = Script.practiceApproach
            case .cane: text = "Tap the screen once to tap your cane."
            }
            return [.speak(text, interrupt: false)]
        }
        return []
    }

    public func applySettings(_ s: GameSettings) {
        settings = s
    }
}
