import AVFoundation

/// Brief spoken guidance through the app's audio session. World sound is
/// ducked while speaking so instructions stay clear.
final class SpeechGuide: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    var onSpeakingChanged: ((Bool) -> Void)?
    private(set) var isSpeaking = false

    override init() {
        super.init()
        synth.delegate = self
        synth.usesApplicationAudioSession = true
    }

    func speak(_ text: String, interrupt: Bool) {
        if interrupt && synth.isSpeaking {
            synth.stopSpeaking(at: .immediate)
        }
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        u.volume = 0.95
        u.postUtteranceDelay = 0.1
        synth.speak(u)
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
    }

    private func setSpeaking(_ s: Bool) {
        guard s != isSpeaking else { return }
        isSpeaking = s
        onSpeakingChanged?(s)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        setSpeaking(true)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        if !synthesizer.isSpeaking { setSpeaking(false) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        if !synthesizer.isSpeaking { setSpeaking(false) }
    }
}
