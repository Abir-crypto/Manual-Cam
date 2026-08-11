import AVFoundation
import Foundation

/// Audio cues for the Multi-Shot Timer (`MULTI_SHOT_TIMER.md`, Task 3): a rising beep
/// sequence in the last ~3 seconds before every shot, plus a distinct shutter sound at
/// the moment of capture.
///
/// **Silent-switch behavior (per user request): respect the mute switch.** The session
/// uses the `.ambient` category, which iOS silences when the hardware mute switch is on
/// and which mixes with other audio rather than interrupting it — so beeps are audible
/// only when the phone isn't muted, and never stomp on music already playing. No bundled
/// sound assets: the three cues are short sine tones synthesized into in-memory WAV data.
final class TimerAudioCuePlayer {
    private let session = AVAudioSession.sharedInstance()
    private let beep: AVAudioPlayer?
    private let finalBeep: AVAudioPlayer?
    private let shutter: AVAudioPlayer?

    init() {
        beep = Self.makePlayer(frequency: 880, duration: 0.08)
        finalBeep = Self.makePlayer(frequency: 1320, duration: 0.11)
        // Lower, slightly longer tone — deliberately distinct from the countdown beeps.
        shutter = Self.makePlayer(frequency: 320, duration: 0.13)
    }

    /// Called when a run starts. `.ambient` + `.mixWithOthers` keeps us out of the way of
    /// any other audio and honors the mute switch.
    func activate() {
        try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    func deactivate() {
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// One countdown beep; the final beep (1s before capture) is pitched higher so the
    /// sequence reads as "rising" / "get ready now".
    func playBeep(isFinal: Bool) {
        play(isFinal ? finalBeep : beep)
    }

    func playShutter() {
        play(shutter)
    }

    private func play(_ player: AVAudioPlayer?) {
        guard let player else { return }
        player.currentTime = 0
        player.play()
    }

    // MARK: - Tone synthesis

    private static func makePlayer(frequency: Double, duration: Double) -> AVAudioPlayer? {
        let data = makeToneWAV(frequency: frequency, duration: duration)
        let player = try? AVAudioPlayer(data: data)
        player?.prepareToPlay()
        return player
    }

    /// Build a mono 16-bit PCM WAV of a single sine tone, with a short linear fade in/out
    /// so the tone doesn't click at its edges.
    private static func makeToneWAV(
        frequency: Double,
        duration: Double,
        sampleRate: Double = 44_100,
        amplitude: Double = 0.6
    ) -> Data {
        let frameCount = max(1, Int(duration * sampleRate))
        let fade = max(1, Int(0.005 * sampleRate))
        var samples = [Int16]()
        samples.reserveCapacity(frameCount)
        for i in 0..<frameCount {
            let t = Double(i) / sampleRate
            var envelope = 1.0
            if i < fade {
                envelope = Double(i) / Double(fade)
            } else if i >= frameCount - fade {
                envelope = Double(frameCount - i) / Double(fade)
            }
            let value = sin(2 * .pi * frequency * t) * amplitude * envelope
            samples.append(Int16((max(-1, min(1, value))) * 32_767))
        }

        let bytesPerSample = 2
        let dataSize = samples.count * bytesPerSample
        let byteRate = Int(sampleRate) * bytesPerSample

        var data = Data()
        func appendASCII(_ s: String) { data.append(s.data(using: .ascii)!) }
        func appendUInt32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func appendUInt16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }

        appendASCII("RIFF")
        appendUInt32(UInt32(36 + dataSize))
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16)                       // PCM fmt chunk size
        appendUInt16(1)                        // PCM
        appendUInt16(1)                        // mono
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(byteRate))
        appendUInt16(UInt16(bytesPerSample))   // block align
        appendUInt16(16)                       // bits per sample
        appendASCII("data")
        appendUInt32(UInt32(dataSize))
        for sample in samples {
            var x = sample.littleEndian
            withUnsafeBytes(of: &x) { data.append(contentsOf: $0) }
        }
        return data
    }
}
