import Foundation

enum SpaceDirection: Equatable {
    case previous
    case next

    init?(action: WindowAction) {
        switch action {
        case .prevSpace: self = .previous
        case .nextSpace: self = .next
        default: return nil
        }
    }

    init?(switchAction: WindowAction) {
        switch switchAction {
        case .switchPrevSpace: self = .previous
        case .switchNextSpace: self = .next
        default: return nil
        }
    }

    var reversed: SpaceDirection {
        self == .next ? .previous : .next
    }

    fileprivate var multiplier: Double {
        self == .next ? 1 : -1
    }
}

enum SpaceGesturePhase: Int64, CaseIterable {
    case began = 1
    case changed = 2
    case ended = 4
}

/// Constructs the reverse-engineered Dock swipe values shared by the
/// window-moving transaction and the display-only Space switcher.
enum SpaceGesture {
    enum Profile {
        case windowMove
        case displaySwitch

        func progressMagnitude(augmented: Bool) -> Double {
            switch self {
            case .windowMove:
                return 0.0001
            case .displaySwitch:
                return augmented ? 0.000016 : Double(Float.leastNonzeroMagnitude)
            }
        }
    }

    enum FieldValue: Equatable {
        case integer(Int64)
        case double(Double)
    }

    struct Field: Equatable {
        let raw: UInt32
        let value: FieldValue
    }

    static let velocity = 1_000.0
    static let payloadField: UInt32 = 4_205

    private enum FieldID {
        static let eventType: UInt32 = 55
        static let hidType: UInt32 = 110
        static let motion: UInt32 = 123
        static let progress: UInt32 = 124
        static let positionX: UInt32 = 125
        static let velocityX: UInt32 = 129
        static let velocityY: UInt32 = 130
        static let phase: UInt32 = 132
        static let phaseAlias: UInt32 = 134
        static let zoomDeltaY: UInt32 = 138
        static let processAlias: UInt32 = 169
    }

    static func fields(
        for phase: SpaceGesturePhase,
        direction: SpaceDirection,
        augmented: Bool,
        timestamp: UInt64,
        profile: Profile = .windowMove
    ) -> [Field] {
        let signedProgress = direction.multiplier * profile.progressMagnitude(augmented: augmented)
        var values = [
            Field(raw: FieldID.eventType, value: .integer(30)),
            Field(raw: FieldID.hidType, value: .integer(23)),
            Field(raw: FieldID.phase, value: .integer(phase.rawValue)),
            Field(raw: FieldID.progress, value: .double(signedProgress)),
            Field(raw: FieldID.motion, value: .integer(1))
        ]

        if !augmented {
            let signedVelocity = direction.multiplier * velocity
            values.append(Field(raw: FieldID.velocityX, value: .double(signedVelocity)))
            values.append(Field(raw: FieldID.velocityY, value: .double(signedVelocity)))
            return values
        }

        values.append(contentsOf: [
            Field(raw: FieldID.phaseAlias, value: .integer(phase.rawValue)),
            Field(raw: FieldID.zoomDeltaY, value: .double(3)),
            Field(raw: FieldID.processAlias, value: .double(Double(timestamp))),
            Field(raw: FieldID.positionX, value: .double(0.1))
        ])
        if phase == .ended {
            values.append(Field(
                raw: FieldID.velocityX,
                value: .double(direction.multiplier * velocity)
            ))
        }
        return values
    }

    static func payload(
        for phase: SpaceGesturePhase,
        direction: SpaceDirection,
        timestamp: UInt64,
        profile: Profile = .windowMove
    ) -> Data {
        let includesVelocity = phase == .ended
        var bytes = Data(capacity: includesVelocity ? 96 : 68)

        // IOHIDSystemQueueElementHeader
        bytes.appendLittleEndian(timestamp)
        bytes.appendLittleEndian(UInt64(0))
        bytes.appendLittleEndian(UInt32(0))
        bytes.appendLittleEndian(UInt32(0))
        bytes.appendLittleEndian(UInt32(includesVelocity ? 2 : 1))

        appendEventHeader(to: &bytes, size: 40, type: 23,
                          options: UInt32(truncatingIfNeeded: phase.rawValue) << 24,
                          depth: 0)
        bytes.appendLittleEndian(fixed1616(0.1))
        bytes.appendLittleEndian(Int32(0))
        bytes.appendLittleEndian(Int32(0))
        bytes.appendLittleEndian(UInt32(0))
        bytes.appendLittleEndian(UInt16(1))
        bytes.appendLittleEndian(UInt16(3))
        bytes.appendLittleEndian(fixed1616(
            direction.multiplier * profile.progressMagnitude(augmented: true)
        ))

        if includesVelocity {
            appendEventHeader(to: &bytes, size: 28, type: 9, options: 0, depth: 1)
            bytes.appendLittleEndian(fixed1616(direction.multiplier * velocity))
            bytes.appendLittleEndian(Int32(0))
            bytes.appendLittleEndian(Int32(0))
        }
        return bytes
    }

    static func payload(
        phase: SpaceGesturePhase,
        direction: SpaceDirection,
        timestamp: UInt64,
        profile: Profile = .windowMove
    ) -> Data {
        payload(for: phase, direction: direction, timestamp: timestamp, profile: profile)
    }

    /// A flattened CGEvent stores an opaque field as a big-endian byte count
    /// and field ID followed by the field's bytes.
    static func payloadRecord(
        for phase: SpaceGesturePhase,
        direction: SpaceDirection,
        timestamp: UInt64,
        profile: Profile = .windowMove
    ) -> Data {
        let payload = payload(
            for: phase,
            direction: direction,
            timestamp: timestamp,
            profile: profile
        )
        var record = Data(payloadRecordHeader(payloadCount: payload.count))
        record.append(payload)
        return record
    }

    static func payloadRecordHeader(payloadCount: Int) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: payloadCount >> 8),
            UInt8(truncatingIfNeeded: payloadCount),
            UInt8(truncatingIfNeeded: payloadField >> 8),
            UInt8(truncatingIfNeeded: payloadField)
        ]
    }

    static func fixed1616(_ value: Double) -> Int32 {
        guard value.isFinite else { return value.sign == .minus ? .min : .max }
        let scaled = value * 65_536
        if scaled >= Double(Int32.max) { return .max }
        if scaled <= Double(Int32.min) { return .min }
        let encoded = Int32(scaled)
        if encoded == 0 && value != 0 {
            return value > 0 ? 1 : -1
        }
        return encoded
    }

    private static func appendEventHeader(
        to data: inout Data,
        size: UInt32,
        type: UInt32,
        options: UInt32,
        depth: UInt8
    ) {
        data.appendLittleEndian(size)
        data.appendLittleEndian(type)
        data.appendLittleEndian(options)
        data.append(depth)
        data.append(contentsOf: [0, 0, 0])
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var encoded = value.littleEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }
}
