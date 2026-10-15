import AVFoundation

/// Renders the world through AVAudioEngine + AVAudioEnvironmentNode (HRTF on
/// headphones). The listener stays at the origin facing -Z; CellarCore supplies
/// every voice already transformed into listener space, so turning is exact and
/// landmarks stay fixed in the world.
final class SpatialAudioEngine {
    let engine = AVAudioEngine()
    let environment = AVAudioEnvironmentNode()
    private let bank: SoundBank
    private let world: World

    private var sourceVoices: [AVAudioPlayerNode] = []
    private var probeVoices: [AVAudioPlayerNode] = []
    private var oneShots: [AVAudioPlayerNode] = []
    private var nextOneShot = 0
    private let uiPlayer = AVAudioPlayerNode()

    private(set) var headphonesConnected = true
    private var worldActive = false
    private var ducked = false
    private var masterLevel: Float = 0

    // Reverb crossfade between rooms.
    private var acoustics: Acoustics?
    private var pendingAcoustics: Acoustics?
    private var reverbLevel: Float = -40
    private var reverbTarget: Float = -40

    init(world: World, bank: SoundBank) {
        self.world = world
        self.bank = bank
        build()
    }

    private func build() {
        engine.attach(environment)
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environment.listenerVectorOrientation = AVAudio3DVectorOrientation(
            forward: AVAudio3DVector(x: 0, y: 0, z: -1), up: AVAudio3DVector(x: 0, y: 1, z: 0))
        // CellarCore computes distance loss along the walking path itself, so the
        // environment's own distance attenuation is neutralised.
        let att = environment.distanceAttenuationParameters
        att.distanceAttenuationModel = .inverse
        att.referenceDistance = 60
        att.maximumDistance = 100
        att.rolloffFactor = 1
        environment.reverbParameters.enable = true
        environment.reverbParameters.level = -40
        environment.outputVolume = 0

        let mono = SoundBank.format
        for _ in world.sources {
            sourceVoices.append(attachSpatialPlayer(format: mono))
        }
        for _ in AudioScene.probeAngles {
            probeVoices.append(attachSpatialPlayer(format: mono))
        }
        for _ in 0..<10 {
            oneShots.append(attachSpatialPlayer(format: mono))
        }
        engine.attach(uiPlayer)
        engine.connect(uiPlayer, to: engine.mainMixerNode, format: mono)
        connectEnvironment()
    }

    private func attachSpatialPlayer(format: AVAudioFormat) -> AVAudioPlayerNode {
        let p = AVAudioPlayerNode()
        engine.attach(p)
        engine.connect(p, to: environment, format: format)
        p.renderingAlgorithm = .HRTFHQ
        p.sourceMode = .pointSource
        p.volume = 0
        return p
    }

    private func connectEnvironment() {
        let hw = engine.outputNode.outputFormat(forBus: 0)
        let rate = hw.sampleRate > 0 ? hw.sampleRate : 44_100
        let stereo = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)
        engine.disconnectNodeOutput(environment)
        engine.connect(environment, to: engine.mainMixerNode, format: stereo)
    }

    // MARK: - Lifecycle

    func start() throws {
        updateRoute()
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        startLoops()
    }

    /// After an interruption, configuration change or media-services reset.
    func restart() {
        engine.stop()
        connectEnvironment()
        do {
            try start()
        } catch {
            NSLog("CellarEscape: audio engine restart failed: \(error)")
        }
    }

    func stop() {
        engine.stop()
    }

    private func startLoops() {
        for (i, s) in world.sources.enumerated() {
            schedule(loop: s.definition.sound, on: sourceVoices[i])
        }
        for (i, p) in probeVoices.enumerated() {
            schedule(loop: "wallPresence.\(i)", on: p)
        }
    }

    private func schedule(loop id: String, on player: AVAudioPlayerNode) {
        guard let buf = bank[id] else { return }
        player.stop()
        player.scheduleBuffer(buf, at: nil, options: [.loops], completionHandler: nil)
        player.play()
    }

    /// Chooses HRTF for headphones and plain panning for the phone speaker.
    func updateRoute() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let headphonePorts: Set<AVAudioSession.Port> = [.headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .usbAudio]
        headphonesConnected = outputs.contains { headphonePorts.contains($0.portType) }
        environment.outputType = headphonesConnected ? .headphones : .builtInSpeakers
        let algorithm: AVAudio3DMixingRenderingAlgorithm = headphonesConnected ? .HRTFHQ : .equalPowerPanning
        for p in sourceVoices + probeVoices + oneShots {
            p.renderingAlgorithm = algorithm
        }
    }

    // MARK: - Per frame

    func setWorldActive(_ active: Bool) { worldActive = active }
    func setDucked(_ d: Bool) { ducked = d }

    func setAcoustics(_ a: Acoustics) {
        guard a != acoustics else { return }
        if acoustics == nil {
            apply(a)
            reverbLevel = reverbTarget
            environment.reverbParameters.level = reverbLevel
        } else {
            pendingAcoustics = a
        }
    }

    private func apply(_ a: Acoustics) {
        acoustics = a
        let preset: AVAudioUnitReverbPreset
        switch a {
        case .smallRoom: preset = .smallRoom; reverbTarget = -9
        case .mediumRoom: preset = .mediumRoom; reverbTarget = -7
        case .largeRoom: preset = .largeRoom; reverbTarget = -6
        case .corridor: preset = .mediumChamber; reverbTarget = -8
        case .stairwell: preset = .largeChamber; reverbTarget = -4
        }
        environment.reverbParameters.loadFactoryReverbPreset(preset)
    }

    func update(sources: [VoiceParams], probes: [VoiceParams], dt: Double) {
        let k = Float(min(1, dt / 0.25))
        let target: Float = worldActive ? (ducked ? 0.5 : 1) : 0
        masterLevel += (target - masterLevel) * k
        environment.outputVolume = masterLevel

        // Reverb crossfade: dip, swap preset, rise.
        if let next = pendingAcoustics {
            reverbLevel -= Float(dt) * 200
            if reverbLevel <= -35 {
                pendingAcoustics = nil
                apply(next)
            }
        } else if reverbLevel < reverbTarget {
            reverbLevel = min(reverbTarget, reverbLevel + Float(dt) * 80)
        } else {
            reverbLevel = reverbTarget
        }
        environment.reverbParameters.level = reverbLevel

        for (i, v) in sources.enumerated() where i < sourceVoices.count {
            apply(v, to: sourceVoices[i])
        }
        for (i, v) in probes.enumerated() where i < probeVoices.count {
            apply(v, to: probeVoices[i])
        }
    }

    private func apply(_ v: VoiceParams, to p: AVAudioPlayerNode) {
        p.position = AVAudio3DPoint(x: Float(v.position.right), y: 0, z: Float(-v.position.forward))
        p.volume = Float(min(1, max(0, v.gain)))
        p.occlusion = Float(-22 * v.muffle)
        p.reverbBlend = Float(v.reverbBlend)
    }

    // MARK: - One-shots

    /// Plays a one-shot at a listener-space position (`height` in metres; footsteps sit below the ears).
    func play(_ id: String, at point: ListenerPoint, height: Float = 0, gain: Float, reverbBlend: Float = 0.4,
              muffle: Float = 0) {
        guard engine.isRunning, let buf = bank[id] else { return }
        let p = oneShots[nextOneShot]
        nextOneShot = (nextOneShot + 1) % oneShots.count
        p.stop()
        p.position = AVAudio3DPoint(x: Float(point.right), y: height, z: Float(-point.forward))
        p.volume = gain
        p.reverbBlend = reverbBlend
        p.occlusion = -22 * muffle
        p.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
        p.play()
    }

    /// Non-spatial interface sound (menu ticks); plays even while the world is faded out.
    func playUI(_ id: String, gain: Float) {
        guard engine.isRunning, let buf = bank[id] else { return }
        uiPlayer.stop()
        uiPlayer.volume = gain
        uiPlayer.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
        uiPlayer.play()
    }
}
