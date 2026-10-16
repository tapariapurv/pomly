import Testing
@testable import Pomly

struct AmbientTests {
    /// Every sound stays in range and isn't silent; brown is darker (smaller sample-to-sample steps) than white.
    @Test func noiseIsBoundedAndShaped() {
        func stats(_ kind: Ambience) -> (peak: Float, energy: Float, step: Float) {
            var n = Noise(kind: kind), last: Float = 0, peak: Float = 0, energy: Float = 0, step: Float = 0
            for _ in 0..<44_100 {
                let v = n.next()
                peak = max(peak, abs(v)); energy += v * v; step += abs(v - last); last = v
            }
            return (peak, energy / 44_100, step / 44_100)
        }
        let white = stats(.white), brown = stats(.brown), rain = stats(.rain)
        for s in [white, brown, rain] {
            #expect(s.peak <= 1)
            #expect(s.energy > 0.0005)
        }
        #expect(brown.step < white.step / 4)
        #expect(stats(.off).peak == 0)
    }
}
