import Foundation

public struct TapSignature: Codable, Equatable, Sendable {
    public var peak: Double
    public var energy: Double
    public var duration: Double
    public var rotation: Double
    public init(peak: Double, energy: Double, duration: Double, rotation: Double) {
        self.peak = peak; self.energy = energy; self.duration = duration; self.rotation = rotation
    }
}

/// A personal vibration template, not Apple's proprietary pinch classifier.
public struct TapProfile: Codable, Sendable {
    public let version: Int
    public let reference: TapSignature
    public let sampleCount: Int
    public init?(signatures: [TapSignature]) {
        guard signatures.count >= 6 else { return nil }
        let valid = signatures.allSatisfy {
            $0.peak.isFinite && $0.energy.isFinite && $0.duration.isFinite && $0.rotation.isFinite &&
            $0.peak >= 0.018 && $0.peak <= 1.5 && $0.energy > 0 &&
            (0.02...0.45).contains($0.duration) && (0...3).contains($0.rotation)
        }
        guard valid else { return nil }
        let median: ([Double]) -> Double = { values in
            let sorted = values.sorted(); return sorted[sorted.count/2]
        }
        let peak = median(signatures.map(\.peak))
        // Reject calibration dominated by inconsistent movements.
        guard signatures.filter({ (0.4...2.5).contains($0.peak / peak) }).count >= 5 else { return nil }
        version = 1; sampleCount = signatures.count
        reference = .init(peak: peak, energy: median(signatures.map(\.energy)),
                          duration: median(signatures.map(\.duration)), rotation: median(signatures.map(\.rotation)))
    }
    public func matches(_ candidate: TapSignature) -> Bool {
        guard version == 1, sampleCount >= 6, reference.peak >= 0.018,
              reference.energy > 0, reference.duration > 0 else { return false }
        let peakRatio = candidate.peak / reference.peak
        let energyRatio = candidate.energy / reference.energy
        let widthRatio = candidate.duration / reference.duration
        return (0.45...2.2).contains(peakRatio) && (0.25...3.5).contains(energyRatio) &&
            (0.4...2.2).contains(widthRatio) && candidate.rotation <= min(3, max(0.65, reference.rotation * 2.5))
    }
}

public enum TapObservation: Sendable {
    case began
    case rejected
    case candidate(TapSignature)
}

/// Finds short vibration pulses using high-pass acceleration and a rotation veto.
/// Requires personal calibration and real-device validation; motion alone cannot prove finger contact.
public struct TapDetector: Sendable {
    public var threshold: Double = 0.025
    public var refractoryPeriod: Double = 0.28
    private var lowPass: Vector3?
    private var previousTime: Double?
    private var quietSince: Double?
    private var armedUntil = -Double.infinity
    public private(set) var lastRejection = ""
    private var suppressUntil = -Double.infinity
    private var candidate: (start: Double, peak: Double, sum: Double, count: Int, rotation: Double, activeEnd: Double)?
    public var isCandidateActive: Bool { candidate != nil }
    public init() {}
    public mutating func suppress(until: Double) {
        suppressUntil = until; candidate = nil; quietSince = nil; armedUntil = -Double.infinity
    }
    public mutating func reset() { self = Self() }
    public mutating func process(_ sample: MotionSample) -> TapObservation? {
        guard sample.isFinite else { return nil }
        guard let low = lowPass, let last = previousTime else {
            lowPass = sample.acceleration; previousTime = sample.time; return nil
        }
        let dt = sample.time - last
        guard dt > 0 else { return nil }
        previousTime = sample.time
        guard dt <= 0.06 else {
            lowPass = sample.acceleration; candidate = nil; quietSince = nil; armedUntil = -Double.infinity
            suppressUntil = sample.time + 0.3
            lastRejection = "sampleGap"
            return .rejected
        }
        let a = 1 - exp(-dt / 0.045)
        lowPass = low + (sample.acceleration - low) * a
        let pulse = (sample.acceleration - lowPass!).magnitude
        let rotation = sample.rotation.magnitude
        guard sample.time >= suppressUntil else { return nil }

        if var current = candidate {
            current.peak = max(current.peak, pulse)
            current.sum += pulse * pulse; current.count += 1
            current.rotation = max(current.rotation, rotation)
            if pulse > max(threshold * 0.5, current.peak * 0.15) { current.activeEnd = sample.time }
            candidate = current
            if rotation > 3 || current.peak > 1.5 {
                candidate = nil; suppressUntil = sample.time + 0.3; quietSince = nil; armedUntil = -Double.infinity
                lastRejection = rotation > 3 ? "rotation" : "impact"
                return .rejected
            }
            // Actual taps may ring for several hundred milliseconds. Finish after
            // the pulse settles, instead of rejecting every pulse still active at 140 ms.
            let settled = sample.time-current.start >= 0.10 && sample.time-current.activeEnd >= 0.04
            if settled || sample.time-current.start >= 0.45 {
                candidate = nil; suppressUntil = sample.time + refractoryPeriod; quietSince = nil; armedUntil = -Double.infinity
                let duration = max(0.02, current.activeEnd - current.start)
                guard settled, duration <= 0.41 else {
                    lastRejection = "unsettled peak=\(current.peak) duration=\(duration) pulse=\(pulse)"
                    return .rejected
                }
                return .candidate(.init(peak: current.peak, energy: sqrt(current.sum / Double(current.count)),
                                        duration: duration, rotation: current.rotation))
            }
            return nil
        }
        if pulse < threshold * 0.6 && rotation < 0.8 {
            if quietSince == nil { quietSince = sample.time }
            if sample.time-(quietSince ?? sample.time) >= 0.09 { armedUntil = sample.time+0.25 }
            return nil
        }
        // Preserve the quiet-state arm through a rising pulse. Clearing it in the
        // low/high threshold gap prevented real, gradual-onset taps from ever starting.
        if pulse >= threshold, rotation < 1.2, sample.time <= armedUntil {
            candidate = (sample.time, pulse, pulse*pulse, 1, rotation, sample.time)
            self.quietSince = nil
            return .began
        }
        quietSince = nil
        return nil
    }
}
