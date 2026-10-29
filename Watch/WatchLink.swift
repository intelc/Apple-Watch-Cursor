import Foundation
import Combine
import CoreBluetooth
import WatchKit
import AppleWatchCursorCore

@MainActor
// Every Core Bluetooth callback is configured on the main queue.
final class WatchLink: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    @Published private(set) var state = "Finding your Mac…" {
        didSet { if state != oldValue { journal.record("link.state", detail: state) } }
    }
    @Published private(set) var hosts: [CBPeripheral] = []
    @Published private(set) var isPaired = false
    @Published private(set) var hostEnabled = false
    @Published private(set) var gesturesArmed = false
    @Published private(set) var supportsOrientation = false
    var onGestureArmRequested: ((Bool) -> Void)?
    var onMouseModeChanged: ((Bool) -> Void)?
    @Published private(set) var isScanning = false
    @Published private(set) var awaitingApproval = false
    var onDisconnect: (() -> Void)?
    var onStall: (() -> Void)?
    var onAxisCalibrationRequest: ((UInt8) -> Void)?
    private var axisRequest: UInt8 = 0
    private let journal = ConnectionJournal(component: "Watch Bluetooth")
    private var manager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var command: CBCharacteristic?
    private var statusCharacteristic: CBCharacteristic?
    private var timer: Timer?
    private var reconnectTask: Task<Void, Never>?
    private var retryAttempt = 0
    private var foreground = true
    private var automaticEnabled = true
    private var session: UInt32 = 0
    private var sequence: UInt32 = 0
    private var outbound = OutboundBuffer()
    private var inFlight: Bool { outbound.pendingReliable != nil }
    private var replyWatchdog = ReplyWatchdog()
    private var needsHello = false
    private var lastStatusRead = 0.0
    private var connectionStarted = 0.0
    private var stalled = false
    private var cachedFailures = 0
    private var preferredID = UserDefaults.standard.string(forKey: "preferredMac").flatMap(UUID.init(uuidString:))
    private var now: Double { ProcessInfo.processInfo.systemUptime }
    func recordLifecycle(_ event: String) { journal.record(event) }
    override init() {
        super.init()
        journal.record("app.started", detail: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")
    }

    func activate() {
        foreground = true
        guard automaticEnabled else { return }
        if manager == nil { manager = CBCentralManager(delegate: self, queue: .main); return }
        if peripheral?.state == .connected {
            replyWatchdog.resume(now: now); connectionStarted = now; stalled = false; startTimer()
            if isPaired { send(.heartbeat) }
            readStatus(force: true)
        } else if peripheral?.state == .connecting {
            connectionStarted = now; startTimer()
        } else { tryConnect() }
    }

    func suspend() {
        foreground = false; timer?.invalidate(); timer = nil
        reconnectTask?.cancel(); reconnectTask = nil
        manager?.stopScan(); isScanning = false
        journal.record("app.background")
    }

    func scan() {
        automaticEnabled = true; foreground = true
        if manager == nil { manager = CBCentralManager(delegate: self, queue: .main) }
        else { tryConnect() }
    }

    private func tryConnect() {
        guard foreground, automaticEnabled, let manager, manager.state == .poweredOn else { return }
        if let peripheral, peripheral.state == .connected || peripheral.state == .connecting { return }
        if cachedFailures < 2, let preferredID, let saved = manager.retrievePeripherals(withIdentifiers: [preferredID]).first {
            connect(saved); return
        }
        guard !isScanning else { return }
        isScanning = true; state = "Finding your Mac…"
        manager.scanForPeripherals(withServices: [CBUUID(string: PilotBluetooth.service)])
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled, let self, self.isScanning else { return }
            self.manager?.stopScan(); self.isScanning = false
            self.state = "Waiting for Apple-Watch-Cursor on Mac"; self.scheduleReconnect()
        }
    }

    func connect(_ host: CBPeripheral) {
        automaticEnabled = true; foreground = true
        reconnectTask?.cancel(); reconnectTask = nil
        manager?.stopScan(); isScanning = false
        if peripheral?.identifier == host.identifier, host.state == .connecting || host.state == .connected { return }
        if let old = peripheral, old.identifier != host.identifier { manager?.cancelPeripheralConnection(old) }
        clearSession(); peripheral = host; host.delegate = self
        session = .random(in: 1...UInt32.max); sequence = 0
        connectionStarted = now; replyWatchdog.resume(now: now); stalled = false
        state = "Connecting to \(host.name ?? "your Mac")…"
        manager?.connect(host); startTimer()
    }

    func disconnect() {
        automaticEnabled = false; reconnectTask?.cancel(); reconnectTask = nil
        timer?.invalidate(); timer = nil; manager?.stopScan(); isScanning = false
        let old = peripheral; clearSession()
        if let old { manager?.cancelPeripheralConnection(old) }
        state = "Disconnected · tap Find Mac to reconnect"
    }

    private func clearSession() {
        let wasPaired = isPaired
        isPaired = false; hostEnabled = false; gesturesArmed = false; supportsOrientation = false; awaitingApproval = false
        command = nil; statusCharacteristic = nil; peripheral = nil
        outbound.reset(); needsHello = false; axisRequest = 0
        if wasPaired { onDisconnect?() }
    }

    private func recover(_ reason: String) {
        timer?.invalidate(); timer = nil
        let old = peripheral; clearSession()
        if let old, old.state != .disconnected { manager?.cancelPeripheralConnection(old) }
        state = reason; scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard foreground, automaticEnabled else { return }
        reconnectTask?.cancel()
        let delay = min(8.0, pow(2, Double(retryAttempt))*0.5)
        retryAttempt = min(retryAttempt+1, 5)
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay*1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.tryConnect()
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }

    private func tick() {
        guard foreground else { return }
        if !isPaired {
            if !awaitingApproval, now-connectionStarted > 20 {
                cachedFailures += 1; recover("Connection delayed · retrying automatically"); return
            }
            readStatus(force: now-lastStatusRead > 1)
            return
        }
        let health = replyWatchdog.tick(now: now, interactive: WKApplication.shared().applicationState == .active)
        if health == .unresponsive { recover("Mac stopped responding · reconnecting automatically"); return }
        if health == .delayed, !stalled {
            stalled = true; state = "Connection delayed · input paused"
            journal.record("reply.delayed", detail: "Eight seconds of active polling without a reply")
            onStall?()
        }
        send(.heartbeat)
        // Write responses prove liveness even when characteristic reads are delayed.
        // Status changes are notified by the Mac. Keep only a sparse fallback
        // read; concurrent reads need not compete with cursor writes every two seconds.
        readStatus(force: now-lastStatusRead > (health == .delayed ? 2 : 10))
    }

    private func readStatus(force: Bool) {
        guard force, let characteristic = statusCharacteristic else { return }
        lastStatusRead = now; peripheral?.readValue(for: characteristic)
    }

    private func sendHello() {
        guard let command, let peripheral else { return }
        if inFlight { needsHello = true; return }
        needsHello = false
        guard let data = CommandFrame(kind: .hello, session: session, sequence: 0).encode() else { return }
        guard outbound.beginHello() else { needsHello = true; return }
        peripheral.writeValue(data, for: command, type: .withResponse)
    }

    func send(_ kind: CommandFrame.Kind, x: Double = 0, y: Double = 0, orientation: Quaternion? = nil) {
        guard isPaired, x.isFinite, y.isFinite, abs(x) <= 1, abs(y) <= 1 else { return }
        guard outbound.enqueue(.init(kind: kind, x: x, y: y, orientation: orientation)) else {
            recover("Connection busy · reconnecting automatically"); return
        }
        flush()
    }

    private func flush() {
        guard let peripheral, let command,
              let next = outbound.next(canSendMovement: peripheral.canSendWriteWithoutResponse) else { return }
        let reliable = !next.kind.isMovement
        guard sequence < UInt32.max else { recover("Refreshing connection…"); return }
        sequence += 1
        guard let data = CommandFrame(kind: next.kind, session: session, sequence: sequence, x: next.x, y: next.y, orientation: next.orientation).encode() else { return }
        peripheral.writeValue(data, for: command, type: reliable ? .withResponse : .withoutResponse)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { tryConnect() }
        else {
            timer?.invalidate(); clearSession(); isScanning = false
            state = central.state == .unauthorized ? "Allow Bluetooth in Settings" : "Bluetooth unavailable · waiting"
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover host: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        if !hosts.contains(where: { $0.identifier == host.identifier }) { hosts.append(host) }
        if peripheral == nil, preferredID == nil || preferredID == host.identifier || cachedFailures >= 2 { connect(host) }
    }
    func centralManager(_ central: CBCentralManager, didConnect host: CBPeripheral) {
        guard host.identifier == peripheral?.identifier else { return }
        state = "Checking Mac trust…"; host.discoverServices([CBUUID(string: PilotBluetooth.service)])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect host: CBPeripheral, error: Error?) {
        guard host.identifier == peripheral?.identifier else { return }
        cachedFailures += 1; recover("Mac unavailable · retrying automatically")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral host: CBPeripheral, error: Error?) {
        guard host.identifier == peripheral?.identifier else { return }
        journal.record("bluetooth.disconnected", detail: error?.localizedDescription ?? "Peer disconnected")
        recover("Disconnected · reconnecting automatically")
    }
    func peripheral(_ host: CBPeripheral, didDiscoverServices error: Error?) {
        guard host.identifier == peripheral?.identifier else { return }
        guard error == nil, let service = host.services?.first(where: { $0.uuid == CBUUID(string: PilotBluetooth.service) }) else {
            recover("Mac service unavailable · retrying"); return
        }
        host.discoverCharacteristics([CBUUID(string: PilotBluetooth.command), CBUUID(string: PilotBluetooth.status)], for: service)
    }
    func peripheral(_ host: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard host.identifier == peripheral?.identifier else { return }
        guard error == nil else { recover("Could not read Mac controls · retrying"); return }
        command = service.characteristics?.first(where: { $0.uuid == CBUUID(string: PilotBluetooth.command) })
        statusCharacteristic = service.characteristics?.first(where: { $0.uuid == CBUUID(string: PilotBluetooth.status) })
        guard let statusCharacteristic, command != nil else { recover("Open the updated Mac companion"); return }
        host.setNotifyValue(true, for: statusCharacteristic)
    }
    func peripheral(_ host: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard host.identifier == peripheral?.identifier else { return }
        guard error == nil, characteristic.isNotifying else { recover("Could not subscribe to Mac · retrying"); return }
        sendHello()
    }
    func peripheral(_ host: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard host.identifier == peripheral?.identifier, characteristic === command else { return }
        outbound.acknowledge()
        if let error {
            let value = error as NSError
            journal.record("write.failed", detail: "\(value.domain) \(value.code): \(value.localizedDescription)")
            if isPaired, value.domain == CBATTErrorDomain, [5, 8, 15].contains(value.code) {
                renewSession(rediscover: false); return
            }
            recover("Open the updated Mac companion · reconnecting"); return
        }
        replyWatchdog.receivedReply(now: now)
        if needsHello { sendHello(); return }
        if !isPaired { readStatus(force: true) }
        flush()
    }
    func peripheral(_ host: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard host.identifier == peripheral?.identifier,
              characteristic.uuid == CBUUID(string: PilotBluetooth.status), error == nil,
              let data = characteristic.value, let status = HostStatus(data: data) else { return }
        replyWatchdog.receivedReply(now: now)
        // A queued read from a previous session must not reset the new session.
        if status.paired, status.session != session { return }
        if status.approvalPending, status.session == session {
            awaitingApproval = true; state = "Click Trust this Watch on Mac"; return
        }
        if status.paired, status.session == session {
            let firstPairedStatus = !isPaired
            let capabilityChanged = supportsOrientation != status.supportsOrientation
            let modeChanged = hostEnabled != status.enabled
            isPaired = true; awaitingApproval = false; hostEnabled = status.enabled; supportsOrientation = status.supportsOrientation
            retryAttempt = 0; cachedFailures = 0; stalled = false
            preferredID = host.identifier
            UserDefaults.standard.set(host.identifier.uuidString, forKey: "preferredMac")
            state = !supportsOrientation ? "Open Apple-Watch-Cursor 0.6 on Mac" : status.enabled ? "Mac control enabled" : "Connected · double finger tap to start"
            if status.axisCalibrationRequest != axisRequest {
                axisRequest = status.axisCalibrationRequest
                outbound.clearQueuedKeepingFlight()
                onAxisCalibrationRequest?(axisRequest)
            }
            if gesturesArmed != status.gesturesArmed || (status.gesturesArmed && (firstPairedStatus || capabilityChanged)) {
                gesturesArmed = status.gesturesArmed; onGestureArmRequested?(gesturesArmed)
            }
            if modeChanged { onMouseModeChanged?(hostEnabled) }
        } else if isPaired {
            renewSession(rediscover: false)
        }
    }
    private func renewSession(rediscover: Bool) {
        let wasPaired = isPaired
        isPaired = false; hostEnabled = false; awaitingApproval = false
        outbound.clearQueuedKeepingFlight()
        session = .random(in: 1...UInt32.max); sequence = 0
        connectionStarted = now; replyWatchdog.resume(now: now)
        if wasPaired { onDisconnect?() }
        journal.record("session.renewing", detail: rediscover ? "Service changed" : "Refreshing trust on existing BLE link")
        state = "Refreshing trusted connection…"
        if rediscover {
            command = nil; statusCharacteristic = nil; outbound.reset(); needsHello = false
            peripheral?.discoverServices([CBUUID(string: PilotBluetooth.service)])
        } else { sendHello() }
    }
    func peripheral(_ host: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard host.identifier == peripheral?.identifier,
              invalidatedServices.contains(where: { $0.uuid == CBUUID(string: PilotBluetooth.service) }) else { return }
        renewSession(rediscover: true)
    }
    func peripheralIsReady(toSendWriteWithoutResponse host: CBPeripheral) {
        if host.identifier == peripheral?.identifier { flush() }
    }
}
