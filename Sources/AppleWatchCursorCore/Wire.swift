import Foundation

public enum PilotBluetooth {
    public static let service = "A23D73E1-FC30-46BC-9680-0771B1CA9150"
    public static let command = "A23D73E2-FC30-46BC-9680-0771B1CA9150"
    public static let status = "A23D73E3-FC30-46BC-9680-0771B1CA9150"
}

/// Compact frames fit the minimum 20-byte BLE payload. No fragmentation or JSON over BLE.
public struct CommandFrame: Equatable, Sendable {
    public enum Kind: UInt8, Sendable {
        case hello = 1, move = 2, click = 3, recenter = 4, pause = 5, heartbeat = 6
        case axisSample = 7, angularMove = 8, axisCalibrationReady = 9
        case singleClick = 10, toggleControl = 11, pose = 12, axisPose = 13
        public var supportsOrientation: Bool { self == .pose || self == .axisPose || self == .singleClick || self == .recenter }
        public var requiresOrientation: Bool { self == .pose || self == .axisPose }
        public var isMovement: Bool { self == .move || self == .angularMove || self == .axisSample || self == .pose || self == .axisPose }
    }
    public let kind: Kind
    public let session: UInt32
    public let sequence: UInt32
    public var x: Double
    public var y: Double
    public var orientation: Quaternion?
    public init(kind: Kind, session: UInt32, sequence: UInt32, x: Double = 0, y: Double = 0, orientation: Quaternion? = nil) {
        self.kind = kind; self.session = session; self.sequence = sequence
        self.x = x; self.y = y; self.orientation = orientation
    }
    public func encode() -> Data? {
        guard x.isFinite, y.isFinite, abs(x) <= 1, abs(y) <= 1 else { return nil }
        var bytes: [UInt8] = [2, kind.rawValue]
        func append(_ value: UInt32) { bytes += (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0*8)) } }
        append(session); append(sequence)
        append(kind == .hello ? 0 : UInt32(UInt16(bitPattern: Int16((x*32767).rounded()))) |
               UInt32(UInt16(bitPattern: Int16((y*32767).rounded()))) << 16)
        if let orientation {
            guard kind.supportsOrientation, let q = orientation.unit else { return nil }
            var values = [q.x,q.y,q.z,q.w]
            let largest = values.indices.max(by: { abs(values[$0]) < abs(values[$1]) })!
            if values[largest] < 0 { values = values.map { -$0 } }
            bytes[1] |= UInt8(largest << 6)
            for index in values.indices where index != largest {
                let value = Int16((min(1,max(-1,values[index]*sqrt(2)))*32767).rounded())
                let bits = UInt16(bitPattern: value)
                bytes += [UInt8(truncatingIfNeeded: bits),UInt8(truncatingIfNeeded: bits >> 8)]
            }
        } else if kind.requiresOrientation { return nil }
        return Data(bytes)
    }
    public init?(data: Data) {
        let b = Array(data)
        guard (b.count == 14 || b.count == 20), b[0] == 2,
              let kind = Kind(rawValue: b[1] & 0x3f) else { return nil }
        if b.count == 14, b[1] & 0xc0 != 0 || kind.requiresOrientation { return nil }
        if b.count == 20, !kind.supportsOrientation { return nil }
        func read(_ index: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(b[index+$1]) << ($1*8) } }
        self.kind = kind; session = read(2); sequence = read(6)
        let payload = read(10)
        x = kind == .hello ? 0 : Double(Int16(bitPattern: UInt16(truncatingIfNeeded: payload))) / 32767
        y = kind == .hello ? 0 : Double(Int16(bitPattern: UInt16(truncatingIfNeeded: payload >> 16))) / 32767
        guard abs(x) <= 1, abs(y) <= 1, session != 0 else { return nil }
        orientation = nil
        if b.count == 20 {
            let largest = Int(b[1] >> 6)
            var values = Array(repeating: 0.0,count: 4), cursor = 14
            for index in values.indices where index != largest {
                let bits = UInt16(b[cursor]) | UInt16(b[cursor+1]) << 8
                let number = Int16(bitPattern: bits)
                guard number != Int16.min else { return nil }
                values[index] = Double(number)/32767/sqrt(2); cursor += 2
            }
            let sum = values.reduce(0) { $0+$1*$1 }
            guard sum <= 1.00001 else { return nil }
            values[largest] = sqrt(max(0,1-sum))
            guard values.allSatisfy({ abs($0) <= values[largest]+0.0001 }) else { return nil }
            orientation = Quaternion(values[0],values[1],values[2],values[3]).unit
            guard orientation != nil else { return nil }
        }
    }
}

public struct HostStatus: Equatable, Sendable {
    public var paired: Bool
    public var enabled: Bool
    public var accessibility: Bool
    public var session: UInt32
    public var approvalPending: Bool
    public var axisCalibrationRequest: UInt8
    public var gesturesArmed: Bool
    public var supportsOrientation: Bool
    public init(paired: Bool = false, enabled: Bool = false, accessibility: Bool = false, session: UInt32 = 0, approvalPending: Bool = false, axisCalibrationRequest: UInt8 = 0, gesturesArmed: Bool = false, supportsOrientation: Bool = false) {
        self.paired = paired; self.enabled = enabled; self.accessibility = accessibility; self.session = session
        self.approvalPending = approvalPending
        self.axisCalibrationRequest = axisCalibrationRequest
        self.gesturesArmed = gesturesArmed; self.supportsOrientation = supportsOrientation
    }
    public func encode() -> Data {
        let flags: UInt8 = (paired ? 1 : 0) | (enabled ? 2 : 0) | (accessibility ? 4 : 0) | (approvalPending ? 8 : 0) | (gesturesArmed ? 16 : 0) | (supportsOrientation ? 32 : 0)
        var bytes = [2, flags] + (0..<4).map { UInt8(truncatingIfNeeded: session >> ($0*8)) }
        if axisCalibrationRequest != 0 { bytes.append(axisCalibrationRequest) }
        return Data(bytes)
    }
    public init?(data: Data) {
        let b = Array(data); guard (b.count == 6 || b.count == 7), b[0] == 2, b[1] < 64 else { return nil }
        paired = b[1]&1 != 0; enabled = b[1]&2 != 0; accessibility = b[1]&4 != 0
        approvalPending = b[1]&8 != 0
        gesturesArmed = b[1]&16 != 0
        supportsOrientation = b[1]&32 != 0
        session = (0..<4).reduce(0) { $0 | UInt32(b[2+$1]) << ($1*8) }
        axisCalibrationRequest = b.count == 7 ? b[6] : 0
    }
}

/// Host-side gate. A new connection/pairing is always disabled until the person enables it on Mac.
public struct SessionGate: Sendable {
    public private(set) var central: UUID?
    public private(set) var session: UInt32 = 0
    public private(set) var enabled = false
    public private(set) var lastSeen: Double = 0
    private var lastSequence: UInt32 = 0
    public init() {}
    public mutating func authorize(_ frame: CommandFrame, from central: UUID, trustedCentral: UUID, now: Double) -> Bool {
        guard frame.kind == .hello, now.isFinite, central == trustedCentral, frame.session != 0 else { return false }
        // Only the Watch explicitly trusted on this Mac may create a session.
        guard self.central == nil else { return self.central == central && session == frame.session }
        self.central = central; session = frame.session; lastSequence = frame.sequence
        lastSeen = now; enabled = false
        return true
    }
    public mutating func setEnabled(_ enabled: Bool) { self.enabled = enabled && central != nil }
    public mutating func reset() { self = Self() }
    /// Stop input promptly on a gap without destroying the person's pairing.
    public mutating func pauseIfStale(now: Double) -> Bool {
        guard now.isFinite, central != nil, enabled, now-lastSeen > 1.5 else { return false }
        enabled = false; return true
    }
    public mutating func expire(now: Double) -> Bool {
        guard now.isFinite, central != nil, now-lastSeen > 300 else { return false }
        reset(); return true
    }
    public func owns(_ frame: CommandFrame, from central: UUID) -> Bool {
        self.central == central && frame.session == session
    }
    public mutating func accept(_ frame: CommandFrame, from central: UUID, now: Double) -> Bool {
        guard now.isFinite, frame.kind != .hello, central == self.central, frame.session == session,
              frame.sequence > lastSequence, now >= lastSeen, now-lastSeen <= 300 else { return false }
        // Even if the watchdog timer was delayed, the first returning packet
        // cannot execute stale input. Re-enabling remains an explicit Mac action.
        if now-lastSeen > 1.5 { enabled = false }
        lastSequence = frame.sequence; lastSeen = now
        if frame.kind == .pause { enabled = false }
        return true
    }
}
