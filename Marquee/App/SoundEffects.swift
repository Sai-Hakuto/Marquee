import Foundation
import AVFoundation

// Console-launcher UI sound effects (the WiiFlow / USB Loader GX feel): a soft tick as covers
// slide, a higher-pitched confirm on launch/Detail, a low blip on back. Every sound is
// SYNTHESIZED into a small PCM buffer once at init — no bundled audio assets to license or ship.
//
// Runs on its OWN AVAudioEngine, deliberately separate from MusicPlayerController's engine:
//  - that engine's mainMixerNode is FFT-tapped (the visualizer) and volume-faded during game
//    sessions, so routing SFX through it would make the bars twitch on every click and the fade
//    would silence the SFX. A second engine keeps them independent.
@MainActor
@Observable
final class SoundEffects {
    enum Effect { case tick, confirm, back }

    var enabled: Bool

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sampleRate = 44_100.0
    private var buffers: [Effect: AVAudioPCMBuffer] = [:]
    private var lastTick: TimeInterval = 0
    private var didSetup = false
    private var started = false

    init() {
        let ud = UserDefaults.standard
        enabled = ud.object(forKey: "soundEffectsEnabled") == nil ? true : ud.bool(forKey: "soundEffectsEnabled")
        // NOTE: the audio engine + buffers are built lazily on first play(), NOT here. Touching
        // AVAudioEngine.mainMixerNode at App-init time (before the window exists) can block the
        // launch when the binary is exec'd directly rather than via LaunchServices — which is
        // exactly how MARQUEE_SELFTEST runs. Deferring keeps startup clean.
    }

    // Build the engine graph + render the effect buffers once, on first use.
    private func setupIfNeeded() {
        guard !didSetup else { return }
        didSetup = true
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        player.volume = 0.5   // subtle; per-effect peak amplitude is also kept low

        buffers[.tick]    = makeTick(format: format)
        buffers[.back]    = makeBack(format: format)
        // The confirm chime is .back's exact shape (envelope, duration, attack) pitched up a
        // musical major third (5:4) — same "voice" as back, just higher, which is the
        // established convention for a positive/confirm cue vs. a cancel (validated against UI
        // sound-design references: high pitch = success/reward, low pitch = rejection/cancel).
        buffers[.confirm] = makeConfirm(format: format)
    }

    // Play an effect. Ticks are rate-limited so a fast carousel fling doesn't machine-gun.
    func play(_ effect: Effect) {
        guard enabled else { return }
        if effect == .tick {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastTick > 0.035 else { return }
            lastTick = now
        }
        setupIfNeeded()
        guard let buffer = buffers[effect] else { return }
        ensureStarted()
        guard started else { return }
        // .interrupts: a new sound replaces whatever is mid-play — avoids overlap pile-up on
        // rapid nav and keeps the click crisp.
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    private func ensureStarted() {
        guard !started else { return }
        do { try engine.start(); player.play(); started = true }
        catch { started = false }
    }

    // MARK: - Synthesis

    // A short soft click: a quick 1.1 kHz blip with a tiny noise transient at the very front.
    private func makeTick(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        render(format: format, duration: 0.045) { t, n in
            let env: Double = exp(-t * 60.0)
            let tone: Double = sin(twoPi * 1100.0 * t)
            var click: Double = 0
            if n < 60 { click = Double.random(in: -1...1) * (1.0 - Double(n) / 60.0) }
            let mix: Double = tone * 0.7 + click * 0.5
            return Float(env * mix * 0.22)
        }
    }

    // Single low, soft blip for back / cancel.
    private func makeBack(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        render(format: format, duration: 0.14) { t, _ in
            let env: Double = exp(-t * 26.0) * min(1.0, t / 0.004)
            let tone: Double = sin(twoPi * 360.0 * t)
            return Float(env * tone * 0.20)
        }
    }

    // .confirm = .back's tone, pitched up a major third (frequency × 5/4) — same envelope/
    // duration/attack, just higher.
    private func makeConfirm(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        render(format: format, duration: 0.14) { t, _ in
            let env: Double = exp(-t * 26.0) * min(1.0, t / 0.004)
            let tone: Double = sin(twoPi * (360.0 * 5.0 / 4.0) * t)
            return Float(env * tone * 0.20)
        }
    }

    private let twoPi = 2.0 * Double.pi

    // Fill a mono buffer from a per-sample generator (time in seconds, sample index).
    private func render(format: AVAudioFormat, duration: Double,
                        _ sample: (_ t: Double, _ n: Int) -> Float) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(duration * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let ch = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        for n in 0..<Int(frames) {
            ch[n] = sample(Double(n) / sampleRate, n)
        }
        return buffer
    }
}
