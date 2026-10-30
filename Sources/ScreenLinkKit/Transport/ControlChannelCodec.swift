import Foundation

/// RGBA color packed in 4 bytes for network transport over WebRTC DataChannels.
public struct StrokeColor: Equatable, Hashable, Sendable {
    public let r: UInt8
    public let g: UInt8
    public let b: UInt8
    public let a: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public static let pairRose = StrokeColor(r: 244, g: 63, b: 94, a: 255)
    public static let pairAmber = StrokeColor(r: 245, g: 158, b: 11, a: 255)
    public static let pairCyan = StrokeColor(r: 6, g: 182, b: 212, a: 255)
}

public enum RemoteMouseButton: UInt8, Equatable, Sendable {
    case left = 0
    case right = 1
    case middle = 2
}

public enum ButtonPhase: UInt8, Equatable, Sendable {
    case down = 0
    case up = 1
}

/// Real-time annotation & remote-control events multiplexed over WebRTC DataChannels.
/// All spatial coordinates are normalized `[0.0, 1.0]` relative to the shared display's
/// top-left origin so mixed-DPI Retina and non-Retina peers map pixel-accurately.
public enum ControlChannelEvent: Equatable, Sendable {
    case cursorMove(peerID: UInt16, normalizedX: Float, normalizedY: Float)
    case strokeBegin(strokeID: UInt32, peerID: UInt16, color: StrokeColor, lineWidthPoints: Float, normalizedX: Float, normalizedY: Float)
    case strokePoint(strokeID: UInt32, normalizedX: Float, normalizedY: Float)
    case strokeEnd(strokeID: UInt32)
    case remoteMouse(button: RemoteMouseButton, phase: ButtonPhase, normalizedX: Float, normalizedY: Float)
    case remoteKey(virtualKeyCode: UInt16, modifierFlags: UInt32, isKeyDown: Bool)
}

public enum ControlCodecError: Error, Equatable {
    case truncatedFrame
    case unsupportedProtocolVersion(UInt8)
    case unknownOpcode(UInt8)
    case invalidEnumPayload
}

/// Compact little-endian binary wire codec (`2` byte header + fixed payload)
/// avoiding JSON allocation overhead on `120 Hz` trackpad/stylus event streams.
public enum ControlChannelCodec {
    public static let protocolVersion: UInt8 = 1

    private enum Opcode: UInt8 {
        case cursorMove = 0x01
        case strokeBegin = 0x02
        case strokePoint = 0x03
        case strokeEnd = 0x04
        case remoteMouse = 0x05
        case remoteKey = 0x06
    }

    public static func encode(_ event: ControlChannelEvent) -> Data {
        var buffer = Data(capacity: 24)
        buffer.append(protocolVersion)

        switch event {
        case let .cursorMove(peerID, x, y):
            buffer.append(Opcode.cursorMove.rawValue)
            appendUInt16(&buffer, peerID)
            appendFloat(&buffer, clampUnit(x))
            appendFloat(&buffer, clampUnit(y))

        case let .strokeBegin(strokeID, peerID, color, width, x, y):
            buffer.append(Opcode.strokeBegin.rawValue)
            appendUInt32(&buffer, strokeID)
            appendUInt16(&buffer, peerID)
            buffer.append(contentsOf: [color.r, color.g, color.b, color.a])
            appendFloat(&buffer, max(1.0, width))
            appendFloat(&buffer, clampUnit(x))
            appendFloat(&buffer, clampUnit(y))

        case let .strokePoint(strokeID, x, y):
            buffer.append(Opcode.strokePoint.rawValue)
            appendUInt32(&buffer, strokeID)
            appendFloat(&buffer, clampUnit(x))
            appendFloat(&buffer, clampUnit(y))

        case let .strokeEnd(strokeID):
            buffer.append(Opcode.strokeEnd.rawValue)
            appendUInt32(&buffer, strokeID)

        case let .remoteMouse(button, phase, x, y):
            buffer.append(Opcode.remoteMouse.rawValue)
            buffer.append(button.rawValue)
            buffer.append(phase.rawValue)
            appendFloat(&buffer, clampUnit(x))
            appendFloat(&buffer, clampUnit(y))

        case let .remoteKey(keyCode, modifiers, isKeyDown):
            buffer.append(Opcode.remoteKey.rawValue)
            appendUInt16(&buffer, keyCode)
            appendUInt32(&buffer, modifiers)
            buffer.append(isKeyDown ? 1 : 0)
        }

        return buffer
    }

    public static func decode(_ data: Data) throws -> ControlChannelEvent {
        guard data.count >= 2 else { throw ControlCodecError.truncatedFrame }
        let base = data.startIndex
        let version = data[base]
        guard version == protocolVersion else {
            throw ControlCodecError.unsupportedProtocolVersion(version)
        }
        guard let opcode = Opcode(rawValue: data[base + 1]) else {
            throw ControlCodecError.unknownOpcode(data[base + 1])
        }

        switch opcode {
        case .cursorMove:
            guard data.count == 12 else { throw ControlCodecError.truncatedFrame }
            let peerID = readUInt16(data, at: base + 2)
            let x = readFloat(data, at: base + 4)
            let y = readFloat(data, at: base + 8)
            return .cursorMove(peerID: peerID, normalizedX: x, normalizedY: y)

        case .strokeBegin:
            guard data.count == 24 else { throw ControlCodecError.truncatedFrame }
            let strokeID = readUInt32(data, at: base + 2)
            let peerID = readUInt16(data, at: base + 6)
            let color = StrokeColor(
                r: data[base + 8],
                g: data[base + 9],
                b: data[base + 10],
                a: data[base + 11]
            )
            let width = readFloat(data, at: base + 12)
            let x = readFloat(data, at: base + 16)
            let y = readFloat(data, at: base + 20)
            return .strokeBegin(
                strokeID: strokeID,
                peerID: peerID,
                color: color,
                lineWidthPoints: width,
                normalizedX: x,
                normalizedY: y
            )

        case .strokePoint:
            guard data.count == 14 else { throw ControlCodecError.truncatedFrame }
            let strokeID = readUInt32(data, at: base + 2)
            let x = readFloat(data, at: base + 6)
            let y = readFloat(data, at: base + 10)
            return .strokePoint(strokeID: strokeID, normalizedX: x, normalizedY: y)

        case .strokeEnd:
            guard data.count == 6 else { throw ControlCodecError.truncatedFrame }
            let strokeID = readUInt32(data, at: base + 2)
            return .strokeEnd(strokeID: strokeID)

        case .remoteMouse:
            guard data.count == 12 else { throw ControlCodecError.truncatedFrame }
            guard let button = RemoteMouseButton(rawValue: data[base + 2]),
                  let phase = ButtonPhase(rawValue: data[base + 3]) else {
                throw ControlCodecError.invalidEnumPayload
            }
            let x = readFloat(data, at: base + 4)
            let y = readFloat(data, at: base + 8)
            return .remoteMouse(button: button, phase: phase, normalizedX: x, normalizedY: y)

        case .remoteKey:
            guard data.count == 9 else { throw ControlCodecError.truncatedFrame }
            let keyCode = readUInt16(data, at: base + 2)
            let modifiers = readUInt32(data, at: base + 4)
            let isDown = data[base + 8] != 0
            return .remoteKey(virtualKeyCode: keyCode, modifierFlags: modifiers, isKeyDown: isDown)
        }
    }

    @inline(__always)
    private static func clampUnit(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(1.0, max(0.0, value))
    }

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        let le = value.littleEndian
        withUnsafeBytes(of: le) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        let le = value.littleEndian
        withUnsafeBytes(of: le) { data.append(contentsOf: $0) }
    }

    private static func appendFloat(_ data: inout Data, _ value: Float) {
        appendUInt32(&data, value.bitPattern)
    }

    private static func readUInt16(_ data: Data, at index: Int) -> UInt16 {
        UInt16(data[index]) | (UInt16(data[index + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at index: Int) -> UInt32 {
        UInt32(data[index]) |
        (UInt32(data[index + 1]) << 8) |
        (UInt32(data[index + 2]) << 16) |
        (UInt32(data[index + 3]) << 24)
    }

    private static func readFloat(_ data: Data, at index: Int) -> Float {
        Float(bitPattern: readUInt32(data, at: index))
    }
}
