import Foundation
import AppleWatchCursorCore

struct Recording: Decodable {
    let samples: [MotionSample]
    let cueTimes: [Double]
}

let args = CommandLine.arguments
guard args.count >= 2 else { fatalError("Usage: TapReplay RECORDING.json [THRESHOLD]") }
let recording = try JSONDecoder().decode(Recording.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
var detector = TapDetector()
if args.count >= 3, let value = Double(args[2]) { detector.threshold = value }
let start = recording.samples.first!.time
var candidates: [(Double, TapSignature)] = []
for sample in recording.samples {
    guard let event = detector.process(sample) else { continue }
    let timestamp = String(format: "%.3f", sample.time-start)
    switch event {
    case .began: print("\(timestamp) began")
    case .rejected: print("\(timestamp) rejected", detector.lastRejection)
    case .candidate(let signature):
        candidates.append((sample.time, signature))
        print("\(timestamp) candidate", String(data: try JSONEncoder().encode(signature), encoding: .utf8)!)
    }
}
print("Threshold", detector.threshold, "candidates", candidates.count)
var matched: [TapSignature] = []
for (index, cue) in recording.cueTimes.enumerated() {
    let end = index+1 < recording.cueTimes.count ? recording.cueTimes[index+1] : recording.samples.last!.time+0.01
    let window = candidates.filter { $0.0 >= cue && $0.0 < end }
    print("Cue", index+1, "candidates", window.count)
    if let signature = window.max(by: { $0.1.peak < $1.1.peak })?.1 { matched.append(signature) }
}
if let profile = TapProfile(signatures: matched) {
    print("Profile", String(data: try JSONEncoder().encode(profile), encoding: .utf8)!)
    print("Matches", candidates.filter { profile.matches($0.1) }.count)
}
if let calibration = GuidedTapTrainer.train(samples: recording.samples, cueTimes: recording.cueTimes) {
    print("Guided calibration", String(data: try JSONEncoder().encode(calibration), encoding: .utf8)!)
    var replay = TapDetector(); replay.threshold = calibration.threshold
    var count = 0
    for sample in recording.samples {
        if case .candidate(let signature) = replay.process(sample), calibration.profile.matches(signature) { count += 1 }
    }
    print("Guided replay matched", count)
} else { print("Guided calibration rejected") }
