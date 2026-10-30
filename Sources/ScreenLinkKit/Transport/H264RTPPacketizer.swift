import CoreMedia
import Foundation

/// Minimal 12-byte RFC 3550 / RFC 6184 RTP packet representation.
public struct RTPPacket: Equatable, Sendable {
    public let payloadType: UInt8
    public let marker: Bool
    public let sequenceNumber: UInt16
    public let timestamp: UInt32
    public let ssrc: UInt32
    public let payload: Data

    public init(
        payloadType: UInt8,
        marker: Bool,
        sequenceNumber: UInt16,
        timestamp: UInt32,
        ssrc: UInt32,
        payload: Data
    ) {
        self.payloadType = payloadType & 0x7F
        self.marker = marker
        self.sequenceNumber = sequenceNumber
        self.timestamp = timestamp
        self.ssrc = ssrc
        self.payload = payload
    }

    /// Serializes the 12-byte fixed RTP header + H.264 payload onto the wire.
    public func serialize() -> Data {
        var out = Data(capacity: 12 + payload.count)
        out.append(0x80) // V=2, P=0, X=0, CC=0
        let mPt: UInt8 = (marker ? 0x80 : 0x00) | (payloadType & 0x7F)
        out.append(mPt)
        out.append(UInt8((sequenceNumber >> 8) & 0xFF))
        out.append(UInt8(sequenceNumber & 0xFF))
        out.append(UInt8((timestamp >> 24) & 0xFF))
        out.append(UInt8((timestamp >> 16) & 0xFF))
        out.append(UInt8((timestamp >> 8) & 0xFF))
        out.append(UInt8(timestamp & 0xFF))
        out.append(UInt8((ssrc >> 24) & 0xFF))
        out.append(UInt8((ssrc >> 16) & 0xFF))
        out.append(UInt8((ssrc >> 8) & 0xFF))
        out.append(UInt8(ssrc & 0xFF))
        out.append(payload)
        return out
    }

    public static func parse(_ wireBytes: Data) -> RTPPacket? {
        guard wireBytes.count > 12 else { return nil }
        let base = wireBytes.startIndex
        let version = (wireBytes[base] >> 6) & 0x03
        guard version == 2 else { return nil }

        let csrcCount = Int(wireBytes[base] & 0x0F)
        let headerLength = 12 + (csrcCount * 4)
        guard wireBytes.count > headerLength else { return nil }

        let marker = (wireBytes[base + 1] & 0x80) != 0
        let payloadType = wireBytes[base + 1] & 0x7F
        let seq = (UInt16(wireBytes[base + 2]) << 8) | UInt16(wireBytes[base + 3])
        let ts =
            (UInt32(wireBytes[base + 4]) << 24) |
            (UInt32(wireBytes[base + 5]) << 16) |
            (UInt32(wireBytes[base + 6]) << 8) |
            UInt32(wireBytes[base + 7])
        let ssrc =
            (UInt32(wireBytes[base + 8]) << 24) |
            (UInt32(wireBytes[base + 9]) << 16) |
            (UInt32(wireBytes[base + 10]) << 8) |
            UInt32(wireBytes[base + 11])

        return RTPPacket(
            payloadType: payloadType,
            marker: marker,
            sequenceNumber: seq,
            timestamp: ts,
            ssrc: ssrc,
            payload: Data(wireBytes[(base + headerLength)...])
        )
    }
}

/// RFC 6184 H.264 RTP packetizer & FU-A reassembler tuned for WebRTC DTLS/SRTP MTU limits.
public struct H264RTPPacketizer: Sendable {
    public static let videoClockRateHz: Double = 90_000.0

    public let ssrc: UInt32
    public let payloadType: UInt8
    public let maxPayloadBytes: Int
    public private(set) var sequenceNumber: UInt16

    public init(
        ssrc: UInt32 = 0x5041_4952,
        payloadType: UInt8 = 96,
        maxPayloadBytes: Int = 1188,
        initialSequenceNumber: UInt16 = 0
    ) {
        self.ssrc = ssrc
        self.payloadType = payloadType & 0x7F
        self.maxPayloadBytes = max(64, maxPayloadBytes)
        self.sequenceNumber = initialSequenceNumber
    }

    public static func rtpTimestamp(for presentationTime: CMTime) -> UInt32 {
        guard presentationTime.isValid, presentationTime.isNumeric else { return 0 }
        let ticks = Int64((presentationTime.seconds * videoClockRateHz).rounded())
        return UInt32(truncatingIfNeeded: ticks)
    }

    /// Packetizes all NAL units of an access unit into Single-NALU and/or FU-A RTP packets.
    public mutating func packetize(nalUnits: [Data], rtpTimestamp: UInt32) -> [RTPPacket] {
        let nonEmptyUnits = nalUnits.filter { !$0.isEmpty }
        guard !nonEmptyUnits.isEmpty else { return [] }

        var packets: [RTPPacket] = []

        for (unitIndex, nalu) in nonEmptyUnits.enumerated() {
            let isLastUnit = (unitIndex == nonEmptyUnits.count - 1)

            if nalu.count <= maxPayloadBytes {
                let seq = nextSequenceNumber()
                packets.append(
                    RTPPacket(
                        payloadType: payloadType,
                        marker: isLastUnit,
                        sequenceNumber: seq,
                        timestamp: rtpTimestamp,
                        ssrc: ssrc,
                        payload: nalu
                    )
                )
                continue
            }

            // Fragment oversized NALU using RFC 6184 Section 5.8 FU-A (type = 28).
            let nalHeader = nalu[nalu.startIndex]
            let fnri = nalHeader & 0xE0
            let nalType = nalHeader & 0x1F
            let fuIndicator: UInt8 = fnri | 28

            let bodyStart = nalu.index(after: nalu.startIndex)
            let bodyCount = nalu.count - 1
            let maxChunkSize = maxPayloadBytes - 2
            var offset = 0

            while offset < bodyCount {
                let chunkLength = min(maxChunkSize, bodyCount - offset)
                let isFirstChunk = (offset == 0)
                let isLastChunk = (offset + chunkLength == bodyCount)

                var fuHeader = nalType
                if isFirstChunk { fuHeader |= 0x80 } // S bit
                if isLastChunk { fuHeader |= 0x40 }  // E bit

                var fragmentPayload = Data(capacity: 2 + chunkLength)
                fragmentPayload.append(fuIndicator)
                fragmentPayload.append(fuHeader)

                let sliceStart = nalu.index(bodyStart, offsetBy: offset)
                let sliceEnd = nalu.index(sliceStart, offsetBy: chunkLength)
                fragmentPayload.append(nalu[sliceStart..<sliceEnd])

                let seq = nextSequenceNumber()
                packets.append(
                    RTPPacket(
                        payloadType: payloadType,
                        marker: isLastUnit && isLastChunk,
                        sequenceNumber: seq,
                        timestamp: rtpTimestamp,
                        ssrc: ssrc,
                        payload: fragmentPayload
                    )
                )
                offset += chunkLength
            }
        }

        return packets
    }

    private mutating func nextSequenceNumber() -> UInt16 {
        let current = sequenceNumber
        sequenceNumber &+= 1
        return current
    }
}

/// Reassembles Single-NALU and FU-A RTP packets back into complete H.264 NAL units.
public struct H264RTPDepacketizer: Sendable {
    private var activeFragmentBuffer = Data()
    private var expectingContinuation = false

    public init() {}

    public mutating func ingest(_ packet: RTPPacket) -> Data? {
        guard !packet.payload.isEmpty else { return nil }
        let base = packet.payload.startIndex
        let indicator = packet.payload[base]
        let packetType = indicator & 0x1F

        if (1...23).contains(packetType) {
            activeFragmentBuffer.removeAll(keepingCapacity: true)
            expectingContinuation = false
            return packet.payload
        }

        // FU-A fragment (type 28)
        guard packetType == 28, packet.payload.count > 2 else {
            activeFragmentBuffer.removeAll(keepingCapacity: true)
            expectingContinuation = false
            return nil
        }

        let fuHeader = packet.payload[base + 1]
        let isStart = (fuHeader & 0x80) != 0
        let isEnd = (fuHeader & 0x40) != 0
        let originalType = fuHeader & 0x1F
        let reconstructedHeader = (indicator & 0xE0) | originalType

        if isStart {
            activeFragmentBuffer.removeAll(keepingCapacity: true)
            activeFragmentBuffer.append(reconstructedHeader)
            activeFragmentBuffer.append(packet.payload[(base + 2)...])
            expectingContinuation = !isEnd
            return isEnd ? activeFragmentBuffer : nil
        }

        guard expectingContinuation else { return nil }
        activeFragmentBuffer.append(packet.payload[(base + 2)...])

        if isEnd {
            expectingContinuation = false
            let completed = activeFragmentBuffer
            activeFragmentBuffer = Data()
            return completed
        }
        return nil
    }
}
