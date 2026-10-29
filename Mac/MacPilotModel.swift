import AppKit
import Combine
import CoreBluetooth
import AppleWatchCursorCore

@MainActor
// Core Bluetooth is explicitly configured to deliver every callback on the main queue.
final class MacPilotModel: NSObject, ObservableObject, @preconcurrency CBPeripheralManagerDelegate {
    @Published private(set) var bluetooth = "Bluetooth is stopped"
    @Published private(set) var advertising = false
    @Published private(set) var paired = false
    @Published private(set) var enabled = false
    @Published private(set) var permission = false
    @Published private(set) var approvalPending = false
    @Published private(set) var hasTrustedWatch = false
    @Published private(set) var offset = PointerOffset.zero
    @Published private(set) var tapCount = 0
    @Published private(set) var mouseClickCount = 0
    private var lastToggle = -Double.infinity
    private var activationGraceUntil = 0.0
    @Published private(set) var event = "Waiting for your Watch"
    @Published private(set) var motionStatus = "No Watch connected"
    @Published var practiceOnly = false { didSet { if practiceOnly != oldValue { disable(); event = "Mode changed. Enable again when ready." } } }
    @Published var flipHorizontal = true { didSet { UserDefaults.standard.set(flipHorizontal, forKey: "flipHorizontal") } }
    @Published var flipVertical = false { didSet { UserDefaults.standard.set(flipVertical, forKey: "flipVertical") } }
    @Published var verticalGain = 2.0 { didSet { UserDefaults.standard.set(verticalGain, forKey: "verticalGain") } }
    enum AxisStep: Int {
        case waiting = -1, topDown, bottomUp, leftRight, rightLeft, review, failed
        var direction: SweepDirection? { SweepDirection(rawValue: rawValue) }
    }
    enum AxisPhase { case demonstrating, positioning, listening, detected }
    @Published var showAxisCalibration = false
    @Published private(set) var axisStep: AxisStep = .waiting
    @Published private(set) var axisPhase: AxisPhase = .demonstrating
    @Published private(set) var axisMessage = ""
    @Published private(set) var axisRetryReason: String?
    @Published private(set) var axisDetectedDirections = Set<SweepDirection>()
    @Published private(set) var axisDemoID = 0
    @Published private(set) var axisPreparationSeconds = 0
    @Published private(set) var axisHasFreshData = false
    var axisCanGo: Bool { axisPhase == .listening && axisHasFreshData && axisDetector.stage == .ready }
    var axisIsMoving: Bool { axisPhase == .listening && axisHasFreshData && axisDetector.stage == .moving }
    @Published private(set) var hasAxisCalibration = false
    private var axisFrames = 0
    private var previousAxisFrames = 0
    private var lastAxisFrame = 0.0
    private var axisProfile: AxisCalibrationProfile?
    private var orientationProfile: OrientationCalibrationProfile?
    private var orientationNeutral: Quaternion?
    private var filteredOrientationOffset = PointerOffset.zero
    private var lastOrientationPacket = 0.0
    private let orientationProfileKey = "Apple-Watch-Cursor.orientationCalibration.v1"
    private var axisDetector = OrientationSweepDetector()
    private var axisMeasurements: [SweepDirection: OrientationSweep] = [:]
    private var axisTransition: Task<Void, Never>?
    private var axisRequest: UInt8 = 0
    private var nextAxisRequest: UInt8 = 0
    private var axisRequestedAt = 0.0
    private var axisActive: Bool { axisRequest != 0 }
    private let axisProfileKey = "Apple-Watch-Cursor.axisCalibration.v1"
    var gestureStandby: Bool { paired && hasAxisCalibration && !axisActive }
    var modeTitle: String {
        if enabled { return practiceOnly ? "PRACTICE" : "MOUSE ON" }
        if !paired { return "CONNECT WATCH" }
        if !hasAxisCalibration { return "CALIBRATE POINTING" }
        if !practiceOnly && !permission { return "ALLOW ACCESSIBILITY" }
        return "STANDBY · DOUBLE TAP TO START"
    }
    private let pointer = PointerController()
    private var manager: CBPeripheralManager?
    private var command: CBMutableCharacteristic?
    private var statusCharacteristic: CBMutableCharacteristic?
    private var subscribers: [UUID: CBCentral] = [:]
    private var gate = SessionGate()
    private var timer: Timer?
    private var tapFeedback = TapFeedback()
    private var lastMotion: Double = 0
    private var receivedMoves = 0
    private var lastMetricsTime = 0.0
    private var previousMoves = 0
    private var lastStatuses: [UUID: Data] = [:]
    private var pendingStatuses = Set<UUID>()
    private var trustedWatch: UUID?
    private var pendingRequest: (central: CBCentral, frame: CommandFrame)?
    private var escapeMonitor: Any?
    private var sleepObserver: NSObjectProtocol?
    private var wantAdvertising = false
    private let journal = ConnectionJournal(component: "Mac")
    private var now: Double { ProcessInfo.processInfo.systemUptime }

    override init() {
        super.init()
        UserDefaults.standard.register(defaults: ["flipHorizontal": true, "flipVertical": false, "verticalGain": 2.0])
        flipHorizontal = UserDefaults.standard.bool(forKey: "flipHorizontal")
        flipVertical = UserDefaults.standard.bool(forKey: "flipVertical")
        verticalGain = min(4, max(0.5, UserDefaults.standard.double(forKey: "verticalGain")))
        trustedWatch = UserDefaults.standard.string(forKey: "trustedWatch").flatMap(UUID.init(uuidString:))
        hasTrustedWatch = trustedWatch != nil
        journal.record("app.started", detail: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")
        if let data = UserDefaults.standard.data(forKey: axisProfileKey),
           let saved = try? JSONDecoder().decode(AxisCalibrationProfile.self, from: data), saved.isValid {
            axisProfile = saved; hasAxisCalibration = true
        }
        if let data = UserDefaults.standard.data(forKey: orientationProfileKey),
           let saved = try? JSONDecoder().decode(OrientationCalibrationProfile.self,from: data), saved.isValid {
            orientationProfile = saved; hasAxisCalibration = true
        }
        permission = pointer.hasPermission
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        // Escape works while this app is focused; global emergency action is the menu-bar Pause.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.disable() }
            return event
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.stop() } }
        start()
    }

    func start() {
        wantAdvertising = true
        if manager == nil { manager = CBPeripheralManager(delegate: self, queue: .main) }
        else if manager?.state == .poweredOn { installService() }
    }

    func stop() {
        failAxisCalibration("Bluetooth stopped. Reconnect and try again.")
        wantAdvertising = false; manager?.stopAdvertising(); manager?.removeAllServices()
        advertising = false; command = nil; statusCharacteristic = nil; subscribers.removeAll()
        gate.reset(); paired = false; enabled = false; lastStatuses = [:]; pendingStatuses = []
        pendingRequest = nil; approvalPending = false
        bluetooth = "Bluetooth is stopped"; event = "Session stopped"
    }

    func forgetWatch() {
        failAxisCalibration("Watch forgotten. Connect a Watch to calibrate.")
        gate.reset(); enabled = false; paired = false
        trustedWatch = nil; hasTrustedWatch = false; pendingRequest = nil; approvalPending = false
        UserDefaults.standard.removeObject(forKey: "trustedWatch")
        event = "Watch forgotten. Trust a Watch to reconnect."; publishStatus()
        journal.record("trust.forgotten")
    }

    func trustPendingWatch() {
        guard let request = pendingRequest else { return }
        trustedWatch = request.central.identifier; hasTrustedWatch = true
        UserDefaults.standard.set(request.central.identifier.uuidString, forKey: "trustedWatch")
        gate.reset()
        paired = gate.authorize(request.frame, from: request.central.identifier,
                                trustedCentral: request.central.identifier, now: now)
        manager?.setDesiredConnectionLatency(.low, for: request.central)
        enabled = false; approvalPending = false; pendingRequest = nil
        event = "Watch trusted. Future connections are automatic."; journal.record("trust.approved")
        publishStatus()
    }

    func setEnabled(_ value: Bool) {
        guard value else { disable(); return }
        permission = pointer.hasPermission
        let age = receivedMoves > 0 ? now-lastMotion : nil
        if let block = MouseControlPolicy.block(paired: paired,calibrated: hasAxisCalibration,calibrating: axisActive,
                                                permission: permission,practice: practiceOnly,motionAge: age) {
            disable(); event = block.rawValue
            journal.record("input.blocked",detail: block.rawValue)
            if block == .permission { requestPermission() }
            return
        }
        pointer.selectPrimaryDisplay()
        gate.setEnabled(true); enabled = gate.enabled; activationGraceUntil = now+3
        event = practiceOnly ? "Practice on · double finger tap to pause" : "Mouse on · primary display · double finger tap to pause"
        journal.record("input.enabled",detail: practiceOnly ? "Practice" : "Live primary display")
        publishStatus()
    }

    func disable() {
        if enabled { journal.record("input.paused", detail: "Mac Pause or mode change") }
        gate.setEnabled(false); enabled = false
        event = "Mouse paused · double finger tap to resume"; publishStatus()
    }
    func requestPermission() { pointer.requestPermission(); permission = pointer.hasPermission }

    private func tick() {
        if axisActive {
            let fresh = now-lastAxisFrame < 0.25
            if axisHasFreshData != fresh { axisHasFreshData = fresh }
            if axisStep == .waiting, now-axisRequestedAt > 12 {
                failAxisCalibration("Wake Apple-Watch-Cursor on Watch and use the latest apps, then retry.")
            } else if (axisPhase == .listening || axisPhase == .positioning), now-lastAxisFrame > 0.5 {
                axisMessage = "Wake the Watch, hold at the starting point, then follow the arrow."
            }
        }
        if enabled, now > activationGraceUntil, now-lastMotion > 1 {
            disable(); event = "Wrist data paused · wake Watch, then double tap to resume"
            journal.record("input.paused",detail: "No fresh wrist movement for one second")
        }
        let previousPermission = permission
        permission = pointer.hasPermission
        if previousPermission && !permission { disable(); event = "Accessibility permission was removed" }
        if gate.pauseIfStale(now: now) {
            enabled = false; event = "Watch messages delayed. Pairing kept; enable again when ready."
            journal.record("input.paused", detail: "No Watch messages for 1.5 seconds")
        }
        if gate.expire(now: now) {
            paired = false; enabled = false; event = "Pairing expired after five minutes without messages."
            journal.record("pairing.expired")
        }
        let motionStatus = !paired ? "No Watch connected" : receivedMoves == 0 ? "Start pointing on Watch" :
            now-lastMotion < 1 ? "Receiving wrist data" : "Connected · waiting for wrist data"
        if self.motionStatus != motionStatus { self.motionStatus = motionStatus }
        if paired, now-lastMetricsTime > 5 {
            journal.record("motion.received", detail: "\(receivedMoves-previousMoves) frames; enabled=\(enabled); lastFrameAge=\(String(format: "%.1f", now-lastMotion))s")
            if axisActive {
                journal.record("axes.stream", detail: "\(axisFrames-previousAxisFrames) frames; \(axisMessage)")
                previousAxisFrames = axisFrames
            }
            previousMoves = receivedMoves; lastMetricsTime = now
        }
        publishStatus()
    }

    private func installService() {
        guard wantAdvertising, command == nil else { return }
        let command = CBMutableCharacteristic(type: CBUUID(string: PilotBluetooth.command),
            properties: [.write, .writeWithoutResponse], value: nil, permissions: [.writeable])
        let status = CBMutableCharacteristic(type: CBUUID(string: PilotBluetooth.status),
            properties: [.read, .notify], value: nil, permissions: [.readable])
        let service = CBMutableService(type: CBUUID(string: PilotBluetooth.service), primary: true)
        service.characteristics = [command, status]
        self.command = command; statusCharacteristic = status
        manager?.add(service)
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn: bluetooth = "Ready to connect"; installService()
        case .poweredOff: bluetooth = "Turn on Bluetooth"; disconnected()
        case .unauthorized: bluetooth = "Allow Bluetooth in System Settings"; disconnected()
        case .unsupported: bluetooth = "Bluetooth LE is unavailable"; disconnected()
        default: bluetooth = "Checking Bluetooth…"; disconnected()
        }
    }

    private func disconnected() {
        failAxisCalibration("Bluetooth unavailable. Reconnect and try again.")
        advertising = false; command = nil; statusCharacteristic = nil
        subscribers.removeAll(); gate.reset(); paired = false; enabled = false; lastStatuses = [:]
        pendingStatuses = []; pendingRequest = nil; approvalPending = false
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard error == nil, wantAdvertising else {
            bluetooth = error?.localizedDescription ?? "Bluetooth is stopped"; command = nil; return
        }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: PilotBluetooth.service)],
                                     CBAdvertisementDataLocalNameKey: "Apple-Watch-Cursor · \(Host.current().localizedName ?? "Mac")"])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        advertising = error == nil && wantAdvertising
        bluetooth = error?.localizedDescription ?? "Visible to your Watch"
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        subscribers[central.identifier] = central; lastStatuses[central.identifier] = nil; publishStatus()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        journal.record("bluetooth.unsubscribed")
        subscribers.removeValue(forKey: central.identifier)
        lastStatuses[central.identifier] = nil; pendingStatuses.remove(central.identifier)
        if pendingRequest?.central.identifier == central.identifier { pendingRequest = nil; approvalPending = false }
        if gate.central == central.identifier {
            failAxisCalibration("Watch disconnected. Reconnect and try again.")
            gate.reset(); paired = false; enabled = false; event = "Watch disconnected. Waiting for automatic reconnect."
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == CBUUID(string: PilotBluetooth.status) else {
            peripheral.respond(to: request, withResult: .attributeNotFound); return
        }
        let data = status(for: request.central.identifier).encode()
        guard request.offset <= data.count else { peripheral.respond(to: request, withResult: .invalidOffset); return }
        request.value = data.subdata(in: request.offset..<data.count)
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        // Core Bluetooth may coalesce writes. Validate the complete batch before applying input.
        var frames: [CommandFrame] = []
        for request in requests {
            guard request.offset == 0, request.central.identifier == first.central.identifier,
                  request.characteristic.uuid == CBUUID(string: PilotBluetooth.command),
                  let value = request.value, let frame = CommandFrame(data: value) else {
                peripheral.respond(to: first, withResult: .invalidAttributeValueLength); return
            }
            frames.append(frame)
        }
        guard let frame = frames.first else {
            peripheral.respond(to: first, withResult: .invalidAttributeValueLength); return
        }
        if frame.kind == .hello {
            guard frames.count == 1, subscribers[first.central.identifier] != nil else {
                peripheral.respond(to: first, withResult: .insufficientAuthorization); return
            }
            guard trustedWatch == first.central.identifier else {
                if gate.central == nil {
                    pendingRequest = (first.central, frame); approvalPending = true
                    event = "A Watch wants to connect. Click Trust this Watch."
                    journal.record("trust.requested")
                }
                peripheral.respond(to: first, withResult: .success); publishStatus(); return
            }
            if gate.session != frame.session { failAxisCalibration("Watch reconnected. Start calibration again."); gate.reset() }
            let accepted = gate.authorize(frame, from: first.central.identifier,
                                          trustedCentral: first.central.identifier, now: now)
            if accepted { peripheral.setDesiredConnectionLatency(.low, for: first.central) }
            paired = gate.central != nil; enabled = gate.enabled
            if accepted { event = "Trusted Watch connected. Enable control when ready."; journal.record("pairing.accepted") }
            peripheral.respond(to: first, withResult: accepted ? .success : .insufficientAuthorization)
            publishStatus(); return
        }
        var draft = gate
        var acceptedFrames: [CommandFrame] = []
        for frame in frames {
            guard draft.accept(frame, from: first.central.identifier, now: now) else {
                // Delayed/duplicate frames from this authenticated session are
                // discarded, not treated as a new pairing failure.
                if draft.owns(frame, from: first.central.identifier) { continue }
                journal.record("command.rejected", detail: "Session mismatch")
                peripheral.respond(to: first, withResult: .insufficientAuthorization); return
            }
            acceptedFrames.append(frame)
        }
        gate = draft; enabled = gate.enabled
        peripheral.respond(to: first, withResult: .success)
        for frame in acceptedFrames { apply(frame) }
    }

    private func mapPointer(_ frame: CommandFrame) -> PointerOffset {
        let input: PointerOffset
        if let q = frame.orientation, let profile = orientationProfile,
           let neutral = orientationNeutral, let vector = neutral.rotation(to: q) {
            input = profile.map(vector)
        } else if frame.kind == .angularMove || frame.kind == .singleClick || frame.kind == .pose {
            let angles = PointerOffset(x: frame.x * .pi,y: frame.y * .pi)
            input = axisProfile?.map(angles) ?? .init(x: angles.x/0.40,y: angles.y/0.32)
        } else { input = .init(x: frame.x,y: frame.y) }
        return input.adjusted(verticalGain: verticalGain,flipX: flipHorizontal,flipY: flipVertical)
    }

    private func apply(_ frame: CommandFrame) {
        switch frame.kind {
        case .move, .angularMove, .pose:
            guard !axisActive else { return }
            receivedMoves += 1
            let target = mapPointer(frame)
            if frame.orientation != nil, orientationProfile != nil {
                let dt = now-lastOrientationPacket
                let a = dt > 0 && dt < 0.2 ? 1-exp(-dt/0.055) : 1
                filteredOrientationOffset.x += (target.x-filteredOrientationOffset.x)*a
                filteredOrientationOffset.y += (target.y-filteredOrientationOffset.y)*a
                lastOrientationPacket = now; offset = filteredOrientationOffset
            } else { offset = target }
            lastMotion = now
            if enabled && !practiceOnly { pointer.move(x: offset.x, y: offset.y) }
        case .recenter:
            guard !axisActive else { return }
            if let q = frame.orientation { orientationNeutral = q }
            filteredOrientationOffset = .zero; lastOrientationPacket = now
            offset = .zero; event = "Recentered"; lastMotion = now
            if enabled && !practiceOnly { pointer.move(x: 0, y: 0) }
        case .click:
            tapCount += 1
            event = enabled ? "Finger tap detected" : "Tap detected · double tap to enter mouse mode"
            journal.record("tap.received",detail: "Detection only; awaiting single/double classification")
        case .singleClick:
            permission = pointer.hasPermission
            let outcome = tapFeedback.receive(now: now,enabled: enabled && !axisActive,practiceOnly: practiceOnly,
                                               hasPermission: permission,lastMotion: receivedMoves > 0 ? lastMotion : nil)
            journal.record("tap.single",detail: outcome.rawValue)
            switch outcome {
            case .liveClick:
                let target = mapPointer(frame)
                pointer.move(x: target.x,y: target.y); pointer.click(x: target.x,y: target.y); mouseClickCount += 1
                event = "Finger tap → click"
            case .practice: event = "Single tap · practice click"
            case .paused: event = "Single tap · mouse is paused"
            case .permissionRequired: event = "Allow Accessibility for mouse control"
            case .staleMotion: event = "Click ignored · wake Watch for fresh wrist data"
            case .rateLimited: event = "Click ignored · too close to the last click"
            }
        case .toggleControl:
            guard now-lastToggle > 0.6 else { return }
            lastToggle = now
            journal.record("gesture.doubleTap",detail: enabled ? "Exit mouse mode" : "Enter mouse mode")
            if enabled { disable() } else { setEnabled(true) }
        case .pause:
            failAxisCalibration("Watch paused. Keep Apple-Watch-Cursor awake and retry calibration.")
            enabled = false; event = "Paused from Watch"
            journal.record("input.paused", detail: "Watch requested pause"); publishStatus()
        case .axisCalibrationReady:
            guard axisActive, axisStep == .waiting, Int((frame.x*255).rounded()) == Int(axisRequest) else { return }
            startAxisSweep(.topDown)
            journal.record("axes.watchReady")
        case .axisSample:
            if axisActive { failAxisCalibration("Install Apple-Watch-Cursor 0.6 on Watch to calibrate in 3D.") }
        case .axisPose:
            guard axisActive, axisStep != .waiting, let q = frame.orientation else { return }
            axisFrames += 1; lastAxisFrame = now; axisHasFreshData = true
            guard (axisPhase == .listening || axisPhase == .positioning), axisPreparationSeconds == 0, let direction = axisStep.direction else { return }
            if let result = axisDetector.process(time: now,pose: q) {
                switch result {
                case .ready: axisPhase = .listening; axisMessage = "Ready · now sweep " + direction.title.lowercased() + "."
                case .moving: axisMessage = "Follow your natural arc, then hold at the end."
                case .interrupted: axisPhase = .positioning; axisMessage = "Data resumed. Hold at the starting point, then try the sweep."
                case .retry: startAxisSweep(direction,reason: "Use one comfortable arc, then hold briefly at the end.")
                case .completed(let measurement): acceptAxisSweep(measurement,direction: direction)
                }
            }
        default: break
        }
    }

    func beginAxisCalibration() {
        guard paired else { return }
        disable(); axisTransition?.cancel(); showAxisCalibration = true; axisStep = .waiting
        axisDetector = OrientationSweepDetector(); axisMeasurements = [:]; axisDetectedDirections = []; axisRetryReason = nil
        axisFrames = 0; previousAxisFrames = 0; lastAxisFrame = 0; axisHasFreshData = false
        nextAxisRequest = nextAxisRequest == 255 ? 1 : nextAxisRequest+1
        axisRequest = nextAxisRequest; axisRequestedAt = now
        axisMessage = "Starting calibration on Watch. Keep its display awake."
        journal.record("axes.requested"); publishStatus()
    }

    private func startAxisSweep(_ direction: SweepDirection, reason: String? = nil) {
        axisTransition?.cancel()
        let previous: SweepDirection? = direction == .bottomUp ? .topDown : direction == .rightLeft ? .leftRight : nil
        let anchor = previous.flatMap { axisMeasurements[$0] }
        let tolerance = anchor.map { max(0.05,($0.start.distance(to: $0.end) ?? 0)*0.25) } ?? 0.08
        axisDetector = OrientationSweepDetector(expectedStart: anchor?.end,tolerance: tolerance)
        axisStep = AxisStep(rawValue: direction.rawValue)!
        axisPhase = .demonstrating; axisDemoID += 1; axisPreparationSeconds = 0
        axisRetryReason = reason
        axisMessage = "Watch the animation. Then it is your turn."
        let request = axisRequest
        axisTransition = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self, self.axisRequest == request, request != 0 else { return }
            self.axisDetector.reset(); self.axisPhase = .positioning
            self.axisMessage = "Move to the " + direction.startName + " starting position."
            for seconds in [2,1] {
                guard !Task.isCancelled, self.axisRequest == request else { return }
                self.axisPreparationSeconds = seconds
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard !Task.isCancelled, self.axisRequest == request else { return }
            self.axisPreparationSeconds = 0; self.axisDetector.reset()
            self.axisMessage = "Hold at the " + direction.startName + " until GO appears."
        }
    }

    private func acceptAxisSweep(_ measurement: OrientationSweep, direction: SweepDirection) {
        let separation = OrientationCalibrationProfile.separationDegrees(measurement,previous: axisMeasurements)
        let diagnostic = "\(direction.title); range=\(String(format: "%.1f",(measurement.start.distance(to: measurement.end) ?? 0)*180 / .pi))deg; separation=\(separation.map { String(format: "%.1f",$0) } ?? "n/a")deg"
        do {
            try OrientationCalibrationProfile.validate(measurement,direction: direction,previous: axisMeasurements)
            if direction == .rightLeft {
                var proposed = axisMeasurements; proposed[direction] = measurement
                _ = try OrientationCalibrationProfile.train(proposed)
            }
        } catch {
            journal.record("axes.sweepRejected",detail: diagnostic + "; " + error.localizedDescription)
            let reason: String
            if let issue = error as? AxisCalibrationError {
                switch issue {
                case .similarAxes: reason = "Movement detected, but it still resembles up/down. Sweep your forearm side to side from your elbow; keep the Watch comfortable. Your vertical checks are kept."
                case .notOpposite: reason = "Movement detected, but it did not reverse your first sweep. Start at the " + direction.startName + ", then follow the arrow."
                default: reason = "Movement detected. " + issue.localizedDescription
                }
            } else { reason = error.localizedDescription }
            startAxisSweep(direction,reason: reason); return
        }
        journal.record("axes.sweepAccepted",detail: diagnostic)
        axisRetryReason = nil
        axisMeasurements[direction] = measurement
        axisDetectedDirections.insert(direction); axisPhase = .detected
        axisMessage = direction == .bottomUp ? "Vertical sweeps complete. Next: left → right." : "Detected · " + direction.title
        journal.record("axes.sweepDetected",detail: direction.title)
        let request = axisRequest
        let checkDuration: UInt64 = direction == .bottomUp ? 2_500_000_000 : 1_200_000_000
        axisTransition?.cancel()
        axisTransition = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: checkDuration)
            guard !Task.isCancelled, let self, self.axisRequest == request, request != 0 else { return }
            if let next = SweepDirection(rawValue: direction.rawValue+1) { self.startAxisSweep(next) }
            else { self.finishAxisCalibration() }
        }
    }

    private func finishAxisCalibration() {
        do {
            let profile = try OrientationCalibrationProfile.train(axisMeasurements)
            let data = try JSONEncoder().encode(profile)
            UserDefaults.standard.set(data,forKey: orientationProfileKey)
            orientationProfile = profile; hasAxisCalibration = true
            flipHorizontal = false; flipVertical = false; verticalGain = 1
            offset = .zero; lastMotion = 0
            axisStep = .review; axisRequest = 0; publishStatus()
            axisMessage = "Calibration saved. Hold your wrist comfortably still, then double finger tap to enter mouse mode."
            event = "Pointing calibrated · double finger tap to enter mouse mode"
            journal.record("axes.saved")
        } catch { failAxisCalibration(error.localizedDescription) }
    }

    func cancelAxisCalibration() {
        axisTransition?.cancel(); axisTransition = nil
        axisRequest = 0; axisDetector.reset(); publishStatus()
    }

    private func failAxisCalibration(_ message: String) {
        guard axisActive else { return }
        axisTransition?.cancel(); axisRequest = 0; axisDetector.reset()
        axisStep = .failed; axisMessage = message
        journal.record("axes.failed",detail: message); publishStatus()
    }

    private func status(for central: UUID) -> HostStatus {
        if gate.central == central {
            return .init(paired: true, enabled: enabled, accessibility: permission, session: gate.session, axisCalibrationRequest: axisRequest, gesturesArmed: gestureStandby, supportsOrientation: true)
        }
        if let pendingRequest, pendingRequest.central.identifier == central {
            return .init(session: pendingRequest.frame.session, approvalPending: true)
        }
        return .init()
    }
    private func publishStatus() {
        guard let manager, let statusCharacteristic else { return }
        for (identifier, central) in subscribers {
            let data = status(for: identifier).encode()
            guard data != lastStatuses[identifier] || pendingStatuses.contains(identifier) else { continue }
            if manager.updateValue(data, for: statusCharacteristic, onSubscribedCentrals: [central]) {
                lastStatuses[identifier] = data; pendingStatuses.remove(identifier)
            } else { pendingStatuses.insert(identifier) }
        }
    }
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) { publishStatus() }
}
