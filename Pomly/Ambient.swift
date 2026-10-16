import SwiftUI
import AVFoundation

/// Background sound during focus, generated on the fly (no audio files).
enum Ambience: Int, CaseIterable, Identifiable {
    case off, white, brown, rain
    static let key = "ambient", volumeKey = "ambientVolume"
    var id: Int { rawValue }
    var name: LocalizedStringResource {
        switch self {
        case .off: "Off"
        case .white: "White Noise"
        case .brown: "Brown Noise"
        case .rain: "Rain"
        }
    }
}

/// Sample generator. White is flat, brown is integrated white (deep rumble), rain is pink noise with sparse droplets.
struct Noise {
    let kind: Ambience
    private var seed: UInt32 = 0x9E3779B9
    private var brown: Float = 0, b0: Float = 0, b1: Float = 0, b2: Float = 0, drop: Float = 0

    init(kind: Ambience) { self.kind = kind }

    /// Uniform in -1...1 (xorshift: cheap and allocation-free on the audio thread).
    private mutating func white() -> Float {
        seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
        return Float(seed) / Float(UInt32.max) * 2 - 1
    }

    mutating func next() -> Float {
        let w = white()
        let v: Float
        switch kind {
        case .off: v = 0
        case .white: v = w * 0.25
        case .brown:
            brown = (brown + 0.02 * w) / 1.02
            v = brown * 3
        case .rain:
            b0 = 0.99765 * b0 + w * 0.0990460 // Paul Kellet's economy pink filter
            b1 = 0.96300 * b1 + w * 0.2965164
            b2 = 0.57000 * b2 + w * 1.0526913
            if white() > 0.9996 { drop = 0.4 + 0.3 * white() }
            drop *= 0.996
            v = (b0 + b1 + b2 + w * 0.1848) * 0.06 + drop * w
        }
        return max(-1, min(1, v))
    }
}

/// Plays the chosen sound while a focus session runs: fades in on start, out on pause, stop or the end.
/// Mixes with other audio, so music keeps playing.
@MainActor final class Ambient {
    static let shared = Ambient()
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var playing = Ambience.off
    private var target: Float = 0
    private var fade: Task<Void, Never>?
    private var end: Task<Void, Never>?

    /// Re-evaluates whenever the session changes.
    func follow() {
        withObservationTracking { update() } onChange: { Task { @MainActor in self.follow() } }
    }

    func update() {
        let s = TimerEngine.shared.snap, d = UserDefaults.shared
        let kind = Ambience(rawValue: d.integer(forKey: Ambience.key)) ?? .off
        let volume = Float(d.object(forKey: Ambience.volumeKey) as? Double ?? 0.5)
        end?.cancel()
        guard kind != .off, s.phase == .focus, s.status == .running, let endDate = s.endDate, endDate > .now else { return ramp(to: 0, over: 1.5) }
        // The session can end with the app in the background (no state change reaches us), so fade out on time anyway.
        end = Task { try? await Task.sleep(for: .seconds(endDate.timeIntervalSinceNow)); if !Task.isCancelled { update() } }
        if kind != playing || !engine.isRunning {
            fade?.cancel()
            engine.stop()
            engine.mainMixerNode.outputVolume = 0
            target = 0
            attach(kind)
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setCategory(.playback, options: .mixWithOthers)
            try? AVAudioSession.sharedInstance().setActive(true)
            #endif
            guard (try? engine.start()) != nil else { return }
        }
        ramp(to: volume, over: target == 0 ? 3 : 0.3)
    }

    private func attach(_ kind: Ambience) {
        if let source { engine.detach(source) }
        let box = NoiseBox(kind: kind)
        let node = AVAudioSourceNode { _, _, frames, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            for f in 0..<Int(frames) {
                let v = box.noise.next()
                for b in buffers { b.mData?.assumingMemoryBound(to: Float.self)[f] = v }
            }
            return noErr
        }
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: rate > 0 ? rate : 44100, channels: 1))
        source = node
        playing = kind
    }

    private func ramp(to volume: Float, over seconds: Double) {
        guard volume != target else { return }
        target = volume
        fade?.cancel()
        fade = Task {
            let from = engine.mainMixerNode.outputVolume, steps = 30
            for i in 1...steps {
                try? await Task.sleep(for: .seconds(seconds / Double(steps)))
                if Task.isCancelled { return }
                engine.mainMixerNode.outputVolume = from + (volume - from) * Float(i) / Float(steps)
            }
            guard volume == 0 else { return }
            engine.stop()
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
        }
    }
}

/// Owned by the render block only (audio thread).
private final class NoiseBox: @unchecked Sendable {
    var noise: Noise
    init(kind: Ambience) { noise = Noise(kind: kind) }
}

struct AmbientSection: View {
    @AppStorage(Ambience.key, store: .shared) private var ambient = 0
    @AppStorage(Ambience.volumeKey, store: .shared) private var volume = 0.5

    var body: some View {
        Section {
            Picker("Sound", selection: $ambient) {
                ForEach(Ambience.allCases) { Text($0.name).tag($0.rawValue) }
            }
            if ambient != 0 {
                Slider(value: $volume, in: 0.05...1) {
                    Text("Volume")
                } minimumValueLabel: {
                    Image(systemName: "speaker.fill").accessibilityHidden(true)
                } maximumValueLabel: {
                    Image(systemName: "speaker.wave.3.fill").accessibilityHidden(true)
                }
                .accessibilityValue(Text(volume, format: .percent.precision(.fractionLength(0))))
            }
        } header: {
            Text("Ambient Sound")
        } footer: {
            Text("Plays softly while you focus, alongside your music.")
        }
        .onChange(of: ambient) { Ambient.shared.update() }
        .onChange(of: volume) { Ambient.shared.update() }
    }
}
