import AVFoundation
import QuartzCore
import UIKit

/// The black gameplay screen. Connects touch input, the game loop and the
/// presentation layers (spatial audio, haptics, speech). Owns no game rules:
/// those live in CellarCore's GameSession.
final class GameViewController: UIViewController {
    private var world: World!
    private var session: GameSession!
    private var scene: AudioScene!
    private let bank = SoundBank()
    private var audio: SpatialAudioEngine?
    private let haptics = HapticsPlayer()
    private let speech = SpeechGuide()
    private let mapView = DevMapView()
    private var displayLink: CADisplayLink?
    private var lastFrame: CFTimeInterval?
    private var ready = false
    private var touchIDs: [ObjectIdentifier: Int] = [:]
    private var nextTouchID = 1
    private var lastStepVariant: [Surface: Int] = [:]

    // Self-test (launch argument -selftest): the autopilot plays through the real app.
    private let selfTestMode = ProcessInfo.processInfo.arguments.contains("-selftest")
    private var autopilot: Autopilot?
    private var selfTestElapsed = 0.0
    private var selfTestFinished = false

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.isMultipleTouchEnabled = true
        // With VoiceOver running, let touches reach the game directly.
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Cellar Escape. Touch the screen directly to play."
        view.accessibilityTraits = .allowsDirectInteraction

        mapView.frame = view.bounds
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.isHidden = true
        view.addSubview(mapView)

        do {
            guard let url = Bundle.main.url(forResource: "basement", withExtension: "json") else {
                throw WorldError.invalid(["basement.json missing from the app bundle"])
            }
            world = try World(WorldDefinition.load(contentsOf: url))
        } catch {
            NSLog("CellarEscape: \(error)")
            speech.speak("The game world could not be loaded.", interrupt: true)
            return
        }

        var settings = SettingsStore.load()
        if selfTestMode {
            settings = GameSettings()
            settings.practiceDone = true
            settings.developerMap = true
        }
        session = GameSession(world: world, settings: settings)
        scene = AudioScene(world: world)
        mapView.world = world
        applySettings(settings)

        speech.onSpeakingChanged = { [weak self] speaking in
            DispatchQueue.main.async { self?.audio?.setDucked(speaking) }
        }
        configureAudioSession()
        observeSystemEvents()

        // Synthesise sounds off the main thread, then start.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.bank.loadAll(ids: SoundSynth.allIDs)
            DispatchQueue.main.async { self?.startGame() }
        }
    }

    private func configureAudioSession() {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playback, mode: .default, options: [])
            try s.setActive(true)
        } catch {
            NSLog("CellarEscape: audio session error: \(error)")
        }
    }

    private func startGame() {
        let engine = SpatialAudioEngine(world: world, bank: bank)
        audio = engine
        observeEngine(engine)
        do {
            try engine.start()
        } catch {
            NSLog("CellarEscape: audio engine failed to start: \(error)")
        }
        haptics.startIfNeeded()
        UIApplication.shared.isIdleTimerDisabled = true

        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        ready = true

        if !engine.headphonesConnected && !selfTestMode {
            speech.speak("Headphones are strongly recommended.", interrupt: true)
        }
        dispatch(session.begin())

        if selfTestMode {
            autopilot = Autopilot(session: session, tour: ["ventRoom", "storage"])
            print("SELFTEST START audioRunning=\(engine.engine.isRunning) sounds=\(bank.buffers.count)/\(SoundSynth.allIDs.count) haptics=\(haptics.supportsHaptics)")
        }
    }

    // MARK: - Game loop

    @objc private func tick(_ link: CADisplayLink) {
        guard ready else { return }
        let now = CACurrentMediaTime()
        let dt = lastFrame.map { now - $0 } ?? 0
        lastFrame = now

        if let pilot = autopilot, !selfTestFinished {
            for g in pilot.step(dt: min(dt, 0.05)) { dispatch(session.handle(g)) }
        }
        dispatch(session.update(dt: dt, now: now))

        let sim = session.sim
        let mix = scene.update(listener: sim.position, heading: sim.heading, room: sim.room,
                               dt: min(dt, 0.1), wallSense: session.settings.wallSense)
        audio?.update(sources: mix.sources, probes: mix.probes, dt: min(dt, 0.1))

        if !mapView.isHidden {
            mapView.playerPosition = sim.position
            mapView.playerHeading = sim.heading
            mapView.playerRadius = world.playerRadius
            mapView.setNeedsDisplay()
        }
        if selfTestMode { selfTestTick(dt) }
    }

    private func selfTestTick(_ dt: Double) {
        guard !selfTestFinished else { return }
        selfTestElapsed += min(dt, 0.05)
        let done = session.phase == .completed
        if done || selfTestElapsed > 200 {
            selfTestFinished = true
            let sim = session.sim
            let rooms = sim.visitedRooms.map { world.rooms[$0].id }.sorted().joined(separator: ",")
            let running = audio?.engine.isRunning ?? false
            let pass = done && sim.visitedRooms.count == world.rooms.count && running
            print("SELFTEST \(pass ? "PASS" : "FAIL") completed=\(done) rooms=\(rooms) audioRunning=\(running) time=\(String(format: "%.1f", selfTestElapsed))s position=\(sim.position)")
            fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(pass ? 0 : 1) }
        }
    }

    // MARK: - Cues -> presentation

    private func dispatch(_ cues: [Cue]) {
        for c in cues {
            switch c {
            case .sim(let e):
                present(e)
            case .speak(let text, let interrupt):
                speech.speak(text, interrupt: interrupt)
                if selfTestMode { print("SPEAK: \(text)") }
            case .stopSpeech:
                speech.stop()
            case .worldAudio(let active):
                audio?.setWorldActive(active)
            case .enteredRoom(let r):
                audio?.setAcoustics(world.rooms[r].acoustics)
            case .caneTap(let echo, let distance):
                playCane(echo: echo, distance: distance)
            case .completion:
                audio?.play("completion", at: ListenerPoint(right: 0, forward: 1.5), gain: 1, reverbBlend: 0.3)
                haptics.play(.completion)
            case .menuTick:
                audio?.playUI("menuTick", gain: 0.4)
            case .settingsChanged(let s):
                applySettings(s)
                if !selfTestMode { SettingsStore.save(s) }
            case .restarted:
                scene.reset()
            }
        }
    }

    private func present(_ e: SimEvent) {
        let sim = session.sim
        func local(_ p: Vec2) -> ListenerPoint { ListenerPoint(world: p, listener: sim.position, heading: sim.heading) }
        switch e {
        case .footstep(let surface, _, let foot, _, let soft):
            // Pick a variant, avoiding immediate repeats.
            var v = Int.random(in: 0..<SoundSynth.footstepVariants)
            if v == lastStepVariant[surface] { v = (v + 1) % SoundSynth.footstepVariants }
            lastStepVariant[surface] = v
            let side = foot == 0 ? -0.14 : 0.14
            audio?.play(SoundSynth.footstepID(surface, v), at: ListenerPoint(right: side, forward: 0.15),
                        height: -1.2, gain: Float(GameViewController.stepGain(surface) * (soft ? 0.45 : 1)),
                        reverbBlend: 0.35)
        case .wallBump(let point):
            audio?.play("bump", at: local(point), height: 0.1, gain: 0.85, reverbBlend: 0.3)
            haptics.play(.bump)
        case .wallContactBegan(let point):
            audio?.play("brush", at: local(point), height: 0.1, gain: 0.4, reverbBlend: 0.2)
            haptics.play(.brush)
        case .wallBrush(let point):
            audio?.play("brush", at: local(point), height: 0.1, gain: 0.22, reverbBlend: 0.2)
        case .threshold:
            audio?.play("threshold", at: ListenerPoint(right: 0, forward: 0.4), gain: 0.3, reverbBlend: 0.1)
            haptics.play(.threshold)
        case .pivot:
            audio?.play("pivot", at: ListenerPoint(right: 0, forward: 0.1), height: -1.2, gain: 0.3, reverbBlend: 0.2)
        case .aligned:
            // A felt tick; if nothing can be felt, a very quiet click instead.
            if !haptics.play(.aligned) {
                audio?.play("alignClick", at: ListenerPoint(right: 0, forward: 1), gain: 0.12, reverbBlend: 0)
            }
        case .reachedExit:
            if selfTestMode { print("SELFTEST reached exit at \(sim.position)") }
        }
        if selfTestMode, case .threshold(_, let to) = e {
            print("SELFTEST entered \(world.rooms[to].id) at \(sim.position)")
        }
    }

    /// Cane tap at the feet, then an echo from the wall ahead. The delay is exaggerated
    /// (about 50 ms per metre) so distance is easy to hear: quick echo = close, none = open.
    private func playCane(echo: Vec2?, distance: Double?) {
        audio?.play("caneTap", at: ListenerPoint(right: 0.1, forward: 0.5), height: -1.0, gain: 0.7, reverbBlend: 0.25)
        guard let echo, let distance else { return }
        let sim = session.sim
        let point = ListenerPoint(world: echo, listener: sim.position, heading: sim.heading)
        let delay = 0.03 + distance * 0.05
        let gain = Float(max(0.15, 0.75 * (1 - distance / GameSession.caneRange)))
        let muffle = Float(min(0.6, distance / GameSession.caneRange * 0.6))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.audio?.play("caneEcho", at: point, gain: gain, reverbBlend: 0.15, muffle: muffle)
        }
    }

    static func stepGain(_ s: Surface) -> Double {
        switch s {
        case .wetConcrete: return 0.5
        case .dryConcrete: return 0.42
        case .woodBoards: return 0.55
        case .metalGrate: return 0.42
        case .grit: return 0.45
        case .stoneStairs: return 0.5
        case .outside: return 0.4
        }
    }

    private func applySettings(_ s: GameSettings) {
        haptics.enabled = s.haptics
        mapView.isHidden = !s.developerMap
    }

    // MARK: - Touch input

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { feed(touches, .began) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { feed(touches, .moved) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { feed(touches, .ended) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { feed(touches, .cancelled) }

    private func feed(_ touches: Set<UITouch>, _ phase: TouchPhase) {
        guard ready, !selfTestMode else { return }
        let now = CACurrentMediaTime()
        var samples: [TouchSample] = []
        for t in touches {
            let key = ObjectIdentifier(t)
            let id: Int
            if let existing = touchIDs[key] {
                id = existing
            } else {
                id = nextTouchID
                nextTouchID += 1
                touchIDs[key] = id
            }
            let p = t.location(in: view)
            samples.append(TouchSample(id: id, phase: phase, x: Double(p.x), y: Double(p.y)))
            if phase == .ended || phase == .cancelled { touchIDs[key] = nil }
        }
        dispatch(session.handleTouches(samples, time: now))
    }

    // MARK: - Interruptions, backgrounding, headphones

    private func observeSystemEvents() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(willResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(didBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(audioInterruption(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        nc.addObserver(self, selector: #selector(routeChanged(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(mediaServicesReset), name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    }

    private func observeEngine(_ engine: SpatialAudioEngine) {
        NotificationCenter.default.addObserver(self, selector: #selector(engineConfigChanged(_:)),
                                               name: .AVAudioEngineConfigurationChange, object: engine.engine)
    }

    @objc private func willResignActive() {
        guard ready, !selfTestMode else { return }
        if session.phase != .paused { dispatch(session.pause(.background)) }
    }

    @objc private func didEnterBackground() {
        guard ready, !selfTestMode else { return }
        speech.stop()
        displayLink?.isPaused = true
        audio?.stop()
        haptics.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    @objc private func didBecomeActive() {
        guard ready else { return }
        // Fresh frame timing: no catch-up step after the gap.
        lastFrame = nil
        displayLink?.isPaused = false
        configureAudioSession()
        if let a = audio, !a.engine.isRunning { a.restart() }
        haptics.startIfNeeded()
        UIApplication.shared.isIdleTimerDisabled = true
        if session.pauseReason == .background || session.pauseReason == .interruption {
            dispatch(session.pausedReminder())
        }
    }

    @objc private func audioInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.ready else { return }
            switch type {
            case .began:
                if self.session.phase != .paused { self.dispatch(self.session.pause(.interruption)) }
            case .ended:
                // Stay paused; the player resumes when ready.
                self.configureAudioSession()
                self.audio?.restart()
                self.dispatch(self.session.pausedReminder())
            @unknown default:
                break
            }
        }
    }

    @objc private func routeChanged(_ note: Notification) {
        let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        let reason = raw.flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.ready else { return }
            self.audio?.updateRoute()
            if reason == .oldDeviceUnavailable {
                self.dispatch(self.session.pause(.headphonesRemoved))
            }
        }
    }

    @objc private func engineConfigChanged(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.audio?.restart()
        }
    }

    @objc private func mediaServicesReset() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.ready else { return }
            // Everything audio-related must be rebuilt from scratch.
            if let old = self.audio {
                NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: old.engine)
            }
            self.configureAudioSession()
            let engine = SpatialAudioEngine(world: self.world, bank: self.bank)
            self.audio = engine
            self.observeEngine(engine)
            try? engine.start()
            if self.session.phase != .paused { self.dispatch(self.session.pause(.interruption)) }
            self.dispatch([.enteredRoom(self.session.sim.room)])
        }
    }
}

enum SettingsStore {
    static let key = "CellarEscape.settings.v1"

    static func load() -> GameSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(GameSettings.self, from: data) else { return GameSettings() }
        return s
    }

    static func save(_ s: GameSettings) {
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: key) }
    }
}
