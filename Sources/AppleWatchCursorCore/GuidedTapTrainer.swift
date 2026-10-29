import Foundation

public struct TapCalibration: Codable, Sendable {
    public let version: Int
    public let threshold: Double
    public let profile: TapProfile
    public var isValid: Bool {
        version == 1 && threshold.isFinite && (0.008...0.5).contains(threshold) && profile.sampleCount >= 6
    }
    public init(threshold: Double, profile: TapProfile) {
        version = 1; self.threshold = threshold; self.profile = profile
    }
}

/// Learns the pulse threshold from rest plus six labeled tap windows. All processing is local.
public enum GuidedTapTrainer {
    public static func train(samples: [MotionSample], cueTimes: [Double]) -> TapCalibration? {
        guard samples.count >= 600, cueTimes.count == 6, let first = samples.first,
              let last = samples.last, cueTimes[0]-first.time >= 2.5,
              last.time-cueTimes[5] >= 1 else { return nil }
        for pair in zip(cueTimes, cueTimes.dropFirst()) {
            guard pair.1-pair.0 >= 1 else { return nil }
        }
        var low = first.acceleration
        var previous = first.time
        var pulses: [(time: Double, value: Double)] = []
        for sample in samples.dropFirst() {
            let dt = sample.time-previous
            guard sample.isFinite, dt > 0, dt <= 0.06 else { return nil }
            let a = 1-exp(-dt/0.045)
            low = low+(sample.acceleration-low)*a
            pulses.append((sample.time, (sample.acceleration-low).magnitude))
            previous = sample.time
        }
        let quiet = pulses.filter { $0.time >= first.time+0.5 && $0.time < first.time+2.5 }.map(\.value).sorted()
        guard quiet.count >= 100 else { return nil }
        let noise = quiet[Int(Double(quiet.count-1)*0.99)]
        var peaks: [Double] = []
        for i in 0..<6 {
            let end = i < 5 ? cueTimes[i+1] : last.time
            guard let peak = pulses.filter({ $0.time >= cueTimes[i] && $0.time < end }).map(\.value).max(),
                  peak > max(0.018, noise*3) else { return nil }
            peaks.append(peak)
        }
        let sortedPeaks = peaks.sorted()
        let threshold = max(0.025, noise*2, sortedPeaks[3]*0.2)
        guard threshold < sortedPeaks[0]*0.5, threshold <= 0.5 else { return nil }
        var detector = TapDetector(); detector.threshold = threshold
        var candidates: [(time: Double, signature: TapSignature)] = []
        for sample in samples {
            if case .candidate(let signature) = detector.process(sample) { candidates.append((sample.time, signature)) }
        }
        var signatures: [TapSignature] = []
        for i in 0..<6 {
            let end = i < 5 ? cueTimes[i+1] : last.time+0.01
            let window = candidates.filter { $0.time >= cueTimes[i] && $0.time < end }
            guard window.count == 1, let signature = window.first?.signature else { return nil }
            signatures.append(signature)
        }
        guard let profile = TapProfile(signatures: signatures), signatures.allSatisfy(profile.matches) else { return nil }
        // Do not accept a calibration that already produces matching false events before cue 1.
        guard !candidates.contains(where: { $0.time < cueTimes[0] && profile.matches($0.signature) }) else { return nil }
        return .init(threshold: threshold, profile: profile)
    }
}
