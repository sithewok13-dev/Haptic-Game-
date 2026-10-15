import AVFoundation

/// Mono 44.1 kHz buffers for every sound id. A bundled file named after an id
/// (e.g. `drip.caf`, `step.woodBoards.0.wav`) replaces the procedural version.
final class SoundBank {
    static let format = AVAudioFormat(standardFormatWithSampleRate: SoundSynth.sampleRate, channels: 1)!

    private(set) var buffers: [String: AVAudioPCMBuffer] = [:]

    /// Renders or loads everything. Call off the main thread; takes well under a second in Release.
    func loadAll(ids: [String]) {
        var result: [String: AVAudioPCMBuffer] = [:]
        for id in ids {
            if let file = SoundBank.loadFile(named: id) {
                result[id] = file
            } else {
                result[id] = SoundBank.buffer(from: SoundSynth.render(id))
            }
        }
        buffers = result
    }

    subscript(id: String) -> AVAudioPCMBuffer? { buffers[id] }

    static func buffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, samples.count))) else {
            return nil
        }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        return buf
    }

    /// Loads and converts a bundled override to mono 44.1 kHz float.
    static func loadFile(named id: String) -> AVAudioPCMBuffer? {
        for ext in ["caf", "wav", "m4a", "aif", "aiff", "mp3"] {
            guard let url = Bundle.main.url(forResource: id, withExtension: ext),
                  let file = try? AVAudioFile(forReading: url),
                  let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                               frameCapacity: AVAudioFrameCount(file.length)),
                  (try? file.read(into: input)) != nil else { continue }
            if file.processingFormat == format { return input }
            guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else { continue }
            let ratio = format.sampleRate / file.processingFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { continue }
            var consumed = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if consumed {
                    status.pointee = .endOfStream
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return input
            }
            if error == nil, output.frameLength > 0 { return output }
        }
        return nil
    }
}
