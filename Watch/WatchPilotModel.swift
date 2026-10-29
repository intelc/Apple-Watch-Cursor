import Foundation
import Combine
import CoreMotion
import WatchKit
import AppleWatchCursorCore

@MainActor
final class WatchPilotModel: ObservableObject {
    enum Mode: Equatable { case paused, recording, pointing, recentering, axes }
    let link = WatchLink()
    @Published private(set) var mode: Mode = .paused
    @Published private(set) var message = "Connect to your Mac"
    @Published private(set) var calibrationCount = 0
    @Published private(set) var profile: TapProfile?
    @Published private(set) var tapCount = 0
    @Published private(set) var sensorRate = 0
    @Published private(set) var device = "Apple Watch"
    @Published private(set) var wrist = "Right wrist"
    @Published private(set) var calibrationIssue = false
    @Published private(set) var cueNumber = 0
    @Published private(set) var recordingSaved = false
    private let motion = CMMotionManager()
    private var mapper = PointerMapper()
    private var detector = TapDetector()
    private var gestures = TapGestureRecognizer()
    private var pendingClickTarget: PointerPose?
    private var lastGestureSample: Double?
    private var latest: MotionSample?
    private var recenterAfter = 0.0
    private var stableSince: Double?
    private var startedAt = 0.0
    private var freezeUntil = 0.0
    private var lastSend = 0.0
    private var sampleTimes: [Double] = []
    private var lastTelemetry = 0.0
    private var pendingMoves: [(time: Double, offset: PointerOffset, orientation: Quaternion?)] = []
    private var lastStableOffset = PointerOffset.zero
    private var lastStableOrientation: Quaternion?
    private var cancellables = Set<AnyCancellable>()
    private var calibrationTimeout: Task<Void, Never>?
    private var recordingSamples: [MotionSample] = []
    private var recordingOrigin: Double?
    private var recordedCues: [Double] = []
    private let calibrationKey = "Apple-Watch-Cursor.guidedTapCalibration.v1"
    private var calibrationThreshold = 0.025

    init() {
        if let data = UserDefaults.standard.data(forKey: calibrationKey),
           let saved = try? JSONDecoder().decode(TapCalibration.self, from: data), saved.isValid {
            profile = saved.profile; calibrationThreshold = saved.threshold
        }
        // Display the actual hardware identifier even when its marketing name isn't in a lookup table.
        var system = utsname(); uname(&system)
        let machineCapacity = MemoryLayout.size(ofValue: system.machine)
        device = withUnsafePointer(to: &system.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: machineCapacity) { String(cString: $0) }
        }
        wrist = WKInterfaceDevice.current().wristLocation == .right ? "Right wrist" : "Set Watch orientation to Right in Settings"
        link.onDisconnect = { [weak self] in
            guard let self, self.isRunning else { return }
            self.pause(send: false); self.message = "Connection lost. Reconnecting automatically."
        }
        link.onStall = { [weak self] in
            guard let self, self.isRunning else { return }
            self.pause(); self.message = "Connection delayed. Pairing kept; enable again on Mac."
        }
        link.onAxisCalibrationRequest = { [weak self] request in
            guard let self else { return }
            if request == 0 {
                if self.mode == .axes { self.pause(send: false); self.message = "Axis calibration ended. Start pointing when ready." }
            } else {
                guard self.link.supportsOrientation else { self.message = "Open Apple-Watch-Cursor 0.6 on Mac"; return }
                self.pause(send: false)
                self.mode = .axes; self.message = "Follow the directions on your Mac. Keep this display awake."
                self.startSensors()
                if self.mode == .axes { self.link.send(.axisCalibrationReady, x: Double(request)/255) }
            }
        }
        link.onGestureArmRequested = { [weak self] armed in
            guard let self else { return }
            if armed, self.mode == .paused, self.canStart { self.startPointing() }
            else if !armed, self.mode == .pointing || self.mode == .recentering { self.pause(send: false) }
        }
        link.onMouseModeChanged = { [weak self] enabled in
            guard let self else { return }
            self.gestures.cancelPending(); self.pendingClickTarget = nil
            if enabled, self.isRunning, self.mode != .axes { self.recenter() }
        }
        link.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        // An in-place upgrade can learn from the user's already recorded six cues.
        // No personal threshold or raw recording is embedded in the application binary.
        if profile == nil {
            struct SavedRecording: Decodable { let reason: String; let cueTimes: [Double]; let samples: [MotionSample] }
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("tap-guided-recording.json")
            if let data = try? Data(contentsOf: url), let recording = try? JSONDecoder().decode(SavedRecording.self, from: data),
               recording.reason == "complete", let calibration = GuidedTapTrainer.train(samples: recording.samples, cueTimes: recording.cueTimes) {
                applyCalibration(calibration); message = "Calibration saved from your recording"
            }
        }
    }

    var isRecording: Bool { mode == .recording }
    var isRunning: Bool { mode == .pointing || mode == .recentering || mode == .axes }
    var canStart: Bool { profile != nil && link.isPaired && link.supportsOrientation }

    func beginCalibration() { recordMissedTaps() }

    func recordMissedTaps() {
        pause()
        cueNumber = 0; recordingSaved = false; recordingSamples = []; recordingOrigin = nil; recordedCues = []
        calibrationCount = 0; calibrationIssue = false
        mode = .recording; message = "Hold still for three seconds. Then tap once at each cue."
        startSensors()
        calibrationTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 16_000_000_000)
            guard !Task.isCancelled, let self, self.isRecording else { return }
            self.pause(reason: "recordingTimeout")
            self.message = "Recording stopped. Keep Apple-Watch-Cursor active and try again."
        }
    }

    func startPointing() {
        guard canStart else { message = profile == nil ? "Calibrate finger taps first" : !link.supportsOrientation ? "Open Apple-Watch-Cursor 0.6 on Mac" : "Connect your Mac first"; return }
        mode = .recentering; message = "Hold your hand comfortably still"
        startSensors(); recenterAfter = ProcessInfo.processInfo.systemUptime + 0.6
    }

    /// The screen button is for recentering, never for substituting a finger click.
    func recenter() {
        guard isRunning, mode != .axes else { return }
        let now = ProcessInfo.processInfo.systemUptime
        mode = .recentering; recenterAfter = now + 0.6; stableSince = nil
        detector.suppress(until: now+1); gestures.reset(); pendingClickTarget = nil
        mapper.reset(); pendingMoves = []
        message = "Hold still to recenter…"
    }

    func pause(send: Bool = true, reason: String = "paused") {
        link.recordLifecycle("input.pause.\(reason)")
        calibrationTimeout?.cancel(); calibrationTimeout = nil
        gestures.reset(); pendingClickTarget = nil; lastGestureSample = nil
        motion.stopAccelerometerUpdates(); motion.stopDeviceMotionUpdates()
        if mode == .recording { saveRecording(reason: reason) }
        if send && isRunning { link.send(.pause) }
        mode = .paused; pendingMoves = []; latest = nil
        message = profile == nil ? "Calibrate your finger taps" : "Ready when you are"
    }

    func activate() { link.recordLifecycle("scene.active"); link.activate() }
    func inactive() {
        link.recordLifecycle("scene.inactive")
        // Dimmed/frontmost is not a disconnect. Visual calibration must stop
        // when its prompts are hidden, but normal pointing may remain frontmost.
        if isRecording { pause(reason: "inactive") }
    }
    func suspend() { pause(reason: "background"); link.suspend() }

    private func saveRecording(reason: String) {
        guard !recordingSamples.isEmpty else { return }
        struct Recording: Encodable {
            let version: Int
            let device: String
            let wrist: String
            let reason: String
            let measuredHz: Int
            let cueTimes: [Double]
            let samples: [MotionSample]
        }
        let data = Recording(version: 1, device: device, wrist: wrist, reason: reason,
                             measuredHz: sensorRate, cueTimes: recordedCues, samples: recordingSamples)
        do {
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(data).write(to: directory.appendingPathComponent("tap-guided-recording.json"), options: .atomic)
            recordingSaved = true
        } catch { recordingSaved = false }
        if reason == "complete" {
            if let calibration = GuidedTapTrainer.train(samples: recordingSamples, cueTimes: recordedCues) {
                applyCalibration(calibration)
            } else { calibrationIssue = true }
        }
        recordingSamples = []
    }

    private func applyCalibration(_ calibration: TapCalibration) {
        guard calibration.isValid else { return }
        profile = calibration.profile; calibrationThreshold = calibration.threshold; calibrationCount = 6
        if let data = try? JSONEncoder().encode(calibration) { UserDefaults.standard.set(data, forKey: calibrationKey) }
    }

    private func startSensors() {
        guard motion.isAccelerometerAvailable && motion.isDeviceMotionAvailable else {
            mode = .paused; message = "Motion sensors unavailable. Use a physical Apple Watch."; return
        }
        detector.reset(); detector.threshold = calibrationThreshold; detector.refractoryPeriod = 0.12
        gestures.reset(); pendingClickTarget = nil; lastGestureSample = nil
        mapper.reset(); mapper.horizontalRange = .pi; mapper.verticalRange = .pi
        latest = nil; sampleTimes = []; pendingMoves = []; lastStableOffset = .zero; lastStableOrientation = nil
        freezeUntil = 0; stableSince = nil; lastSend = 0; sensorRate = 0
        startedAt = ProcessInfo.processInfo.systemUptime; lastTelemetry = 0
        detector.suppress(until: startedAt + 0.8)
        if mode == .axes {
            // Pose calibration needs orientation, not the high-rate raw stream
            // used to recognize finger vibrations. Avoid cross-stream joins.
            motion.deviceMotionUpdateInterval = 1.0/60
            motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] attitude, error in
                guard let self else { return }
                if let error { self.pause(reason: "axisSensorError"); self.message = error.localizedDescription; return }
                guard let attitude else { return }
                let r = attitude.rotationRate, q = attitude.attitude.quaternion
                self.process(.init(time: attitude.timestamp, acceleration: .init(0,0,0),
                    rotation: .init(r.x,r.y,r.z), yaw: attitude.attitude.yaw, pitch: attitude.attitude.pitch, orientation: .init(q.x,q.y,q.z,q.w)))
            }
            link.recordLifecycle("axes.sensorStarted")
            return
        }
        motion.deviceMotionUpdateInterval = 1.0/100
        motion.accelerometerUpdateInterval = 1.0/100
        // Both streams share sensor-boot timestamps. The raw accelerometer drives pulse detection.
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical)
        motion.startAccelerometerUpdates(to: .main) { [weak self] data, error in
            guard let self else { return }
            if let error { self.pause(); self.message = error.localizedDescription; return }
            guard let data, let attitude = self.motion.deviceMotion,
                  abs(attitude.timestamp-data.timestamp) < 0.06 else { return }
            let a = data.acceleration, r = attitude.rotationRate, q = attitude.attitude.quaternion
            self.process(.init(time: data.timestamp, acceleration: .init(a.x, a.y, a.z),
                rotation: .init(r.x, r.y, r.z), yaw: attitude.attitude.yaw, pitch: attitude.attitude.pitch, orientation: .init(q.x,q.y,q.z,q.w)))
        }
    }

    private func process(_ sample: MotionSample) {
        guard sample.isFinite, mode != .paused else { return }
        if let lastGestureSample, sample.time-lastGestureSample > 0.1 {
            gestures.reset(); pendingClickTarget = nil
        }
        lastGestureSample = sample.time
        latest = sample
        sampleTimes.append(sample.time); sampleTimes.removeAll { sample.time-$0 > 1 }
        let elapsed = sampleTimes.count > 1 ? sample.time-sampleTimes[0] : 0
        // Sample at 100 Hz without invalidating the SwiftUI hierarchy on every sensor callback.
        if elapsed > 0.6, sample.time-lastTelemetry > 0.5 {
            let rate = Int((Double(sampleTimes.count-1)/elapsed).rounded())
            if sensorRate != rate { sensorRate = rate }
            lastTelemetry = sample.time
        }
        if mode != .axes && sample.time-startedAt > 3 && sensorRate < 65 {
            pause(reason: "lowSampleRate"); calibrationIssue = true
            message = "Motion rate too low for this tap detector. \(sensorRate) Hz received; need at least 65."
            return
        }
        if mode == .axes {
            if sample.time-lastSend >= 1.0/40 {
                link.send(.axisPose, x: sample.yaw / .pi, y: -sample.pitch / .pi, orientation: sample.orientation)
                lastSend = sample.time
            }
            return
        }
        if mode == .recording {
            if recordingOrigin == nil { recordingOrigin = sample.time }
            recordingSamples.append(sample)
            let elapsed = sample.time-(recordingOrigin ?? sample.time)
            if elapsed >= 12 {
                pause(reason: "complete")
                message = calibrationCount == 6 ? "Calibration saved. Try Practice on Mac." :
                    recordingSaved ? "Recording saved. Taps need more tuning." : "Could not save recording. Try again."
            } else if elapsed >= 3 {
                let cue = min(6, 1 + Int((elapsed-3)/1.5))
                if cue != cueNumber {
                    cueNumber = cue; recordedCues.append(sample.time)
                    message = "Tap index finger to thumb now"
                }
            }
            return
        }
        if mode == .recentering {
            guard sample.time > recenterAfter else { return }
            if sample.rotation.magnitude < 0.15 {
                if stableSince == nil { stableSince = sample.time }
                if sample.time-(stableSince ?? sample.time) > 0.35 {
                    mapper.recenter(yaw: sample.yaw, pitch: sample.pitch, time: sample.time)
                    lastStableOffset = .zero; lastStableOrientation = sample.orientation
                    detector.suppress(until: sample.time+0.6)
                    link.send(.recenter, orientation: sample.orientation); mode = .pointing; message = "Double finger tap to toggle mouse mode"
                    // No haptic here: its motor vibration could contaminate the tap detector.
                }
            } else { stableSince = nil }
            return
        }

        if let observation = detector.process(sample) {
            switch observation {
            case .began:
                gestures.began(time: sample.time)
                freezeUntil = sample.time + 0.12
                pendingMoves = [] // Discard the buffered lead-in to a finger pulse.
            case .candidate(let signature):
                if mode == .pointing, profile?.matches(signature) == true {
                    link.send(.click); tapCount += 1
                    let previousTarget = pendingClickTarget
                    let action = gestures.recognized(time: sample.time)
                    if let action { sendGesture(action,target: previousTarget) }
                    pendingClickTarget = gestures.hasPendingTap ? .init(offset: lastStableOffset,orientation: lastStableOrientation) : nil
                    message = action == .toggleControl ? "Switching mouse mode…" : "Finger tap detected · \(tapCount)"
                } else if let action = gestures.rejected(time: sample.time) { sendGesture(action,target: pendingClickTarget); pendingClickTarget = nil }
            case .rejected:
                if let action = gestures.rejected(time: sample.time) { sendGesture(action,target: pendingClickTarget); pendingClickTarget = nil }
            }
        }

        guard mode == .pointing else { return }
        if let action = gestures.poll(time: sample.time) {
            sendGesture(action,target: pendingClickTarget); pendingClickTarget = nil
        }
        if detector.isCandidateActive { freezeUntil = sample.time+0.12 }
        // Keep mapper timestamps live during the click freeze without forwarding a disturbed position.
        guard let offset = mapper.update(yaw: sample.yaw, pitch: sample.pitch, time: sample.time) else { return }
        guard sample.time > freezeUntil else {
            // Hold the last stable target throughout a finger pulse, while still
            // refreshing the host's motion freshness gate for longer real taps.
            if sample.time-lastSend >= 1.0/40 {
                link.send(.pose, x: lastStableOffset.x, y: lastStableOffset.y, orientation: lastStableOrientation); lastSend = sample.time
            }
            return
        }
        pendingMoves.append((sample.time, offset, sample.orientation))
        // 50 ms look-behind prevents the first acceleration spike from jerking the cursor before detection.
        if let next = pendingMoves.last(where: { sample.time-$0.time >= 0.05 }), sample.time-lastSend >= 1.0/40 {
            link.send(.pose, x: next.offset.x, y: next.offset.y, orientation: next.orientation); lastSend = sample.time
            lastStableOffset = next.offset; lastStableOrientation = next.orientation
            pendingMoves.removeAll { $0.time <= next.time }
        }
    }
    private func sendGesture(_ action: TapGestureRecognizer.Action, target: PointerPose?) {
        switch action {
        case .toggleControl: link.send(.toggleControl)
        case .singleClick:
            guard let target else { return }
            link.send(.singleClick,x: target.offset.x,y: target.offset.y,orientation: target.orientation)
        }
    }

}
