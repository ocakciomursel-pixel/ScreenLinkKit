import CoreGraphics
import CoreMedia
import CoreVideo
import XCTest
@testable import ScreenLinkKit

final class ScreenLinkKitTests: XCTestCase {

    // MARK: - 1. Compositor App Masking Policy

    func testAppMaskPolicyExcludesPrivateAppsAndPreservesExceptedWindowIDs() {
        let apps = [
            RunningAppDescriptor(bundleIdentifier: "com.apple.dt.Xcode", applicationName: "Xcode", processID: 101),
            RunningAppDescriptor(bundleIdentifier: "com.tinyspeck.slackmacgap", applicationName: "Slack", processID: 102),
            RunningAppDescriptor(bundleIdentifier: "com.1password.1password", applicationName: "1Password", processID: 103),
            RunningAppDescriptor(bundleIdentifier: "com.apple.MobileSMS", applicationName: "Messages", processID: 104)
        ]

        let windows = [
            WindowDescriptor(windowID: 5001, owningBundleIdentifier: "com.apple.dt.Xcode", title: "PairSession.swift"),
            WindowDescriptor(windowID: 5002, owningBundleIdentifier: "com.tinyspeck.slackmacgap", title: "DMs"),
            WindowDescriptor(windowID: 5003, owningBundleIdentifier: "com.tinyspeck.slackmacgap", title: "#engineering-incident"),
            WindowDescriptor(windowID: 5004, owningBundleIdentifier: "com.tinyspeck.slackmacgap", title: "Hidden Offscreen", isOnScreen: false)
        ]

        let policy = AppMaskPolicy(
            excludedBundleIdentifiers: AppMaskPolicy.defaultMaskedBundleIdentifiers,
            exceptedWindowIDs: [5003, 5004]
        )

        let result = policy.evaluate(applications: apps, windows: windows)
        XCTAssertEqual(
            Set(result.excludedApps.map(\.bundleIdentifier)),
            ["com.tinyspeck.slackmacgap", "com.1password.1password", "com.apple.MobileSMS"]
        )
        // Only on-screen excepted windows should pass through to SCContentFilter(exceptingWindows:).
        XCTAssertEqual(result.exceptedWindows.map(\.windowID), [5003])
    }

    // MARK: - 2. VideoToolbox Zero-B-Frame H.264 Encoding

    func testVideoToolboxEncoderEmitsParameterSetsAndZeroBFrames() throws {
        let width = 1280
        let height = 720
        let config = VideoEncoderConfiguration(
            width: width,
            height: height,
            averageBitrateBps: 5_000_000,
            expectedFPS: 60,
            maxKeyframeIntervalSeconds: 4
        )
        let encoder = try LowLatencyVideoEncoder(configuration: config)

        var emittedFrames: [EncodedVideoFrame] = []
        let lock = NSLock()
        encoder.onEncodedFrame = { frame in
            lock.withLock {
                emittedFrames.append(frame)
            }
        }

        for index in 0..<12 {
            let buffer = try Self.makeTestPixelBuffer(width: width, height: height, seed: index)
            let pts = CMTime(value: CMTimeValue(index), timescale: 60)
            try encoder.encode(
                pixelBuffer: buffer,
                presentationTimestamp: pts,
                duration: CMTime(value: 1, timescale: 60),
                forceKeyframe: index == 0 || index == 6
            )
            if index == 5 {
                encoder.updateTargetBitrate(3_500_000)
            }
        }
        encoder.flush()

        XCTAssertEqual(emittedFrames.count, 12)
        guard let first = emittedFrames.first else {
            XCTFail("Expected at least one encoded H.264 access unit")
            return
        }

        XCTAssertTrue(first.isKeyframe, "First access unit must be an IDR keyframe")
        let firstNalTypes = first.nalUnits.compactMap { $0.first.map { $0 & 0x1F } }
        XCTAssertTrue(firstNalTypes.contains(7), "Keyframe must prepend H.264 SPS (NAL type 7)")
        XCTAssertTrue(firstNalTypes.contains(8), "Keyframe must prepend H.264 PPS (NAL type 8)")
        XCTAssertTrue(firstNalTypes.contains(5), "Keyframe must contain IDR slice (NAL type 5)")

        // Forced PLI recovery keyframe at index 6
        XCTAssertTrue(emittedFrames[6].isKeyframe, "Explicitly forced PLI recovery frame must be an IDR keyframe")

        // Verify strict monotonically increasing PTS emission (proves zero B-frame reordering).
        var previousPTS = CMTime.negativeInfinity
        for frame in emittedFrames {
            XCTAssertGreaterThan(CMTimeCompare(frame.presentationTimestamp, previousPTS), 0)
            previousPTS = frame.presentationTimestamp
        }
    }

    // MARK: - 3. RFC 6184 H.264 RTP Packetization & FU-A Reassembly

    func testH264RTPPacketizerFragmentsOversizedIDRAndWrapsSequenceNumbers() {
        let sps = Data([0x67, 0x64, 0x00, 0x1F, 0xAC, 0xD9])
        let pps = Data([0x68, 0xEB, 0xE3, 0xCB, 0x22, 0xC0])
        var oversizedIDR = Data([0x65]) // NRI=3, Type=5 (IDR)
        for i in 0..<3400 {
            oversizedIDR.append(UInt8(i & 0xFF))
        }

        var packetizer = H264RTPPacketizer(
            ssrc: 0x1234_5678,
            payloadType: 96,
            maxPayloadBytes: 1188,
            initialSequenceNumber: 65534
        )

        let timestamp = H264RTPPacketizer.rtpTimestamp(for: CMTime(value: 1, timescale: 2))
        XCTAssertEqual(timestamp, 45_000)

        let packets = packetizer.packetize(nalUnits: [sps, pps, oversizedIDR], rtpTimestamp: timestamp)
        XCTAssertEqual(packets.count, 5) // 1 SPS + 1 PPS + 3 FU-A fragments

        // Verify 16-bit RTP sequence wrap-around across 65535 -> 0.
        XCTAssertEqual(packets.map(\.sequenceNumber), [65534, 65535, 0, 1, 2])

        // Marker bit must be set ONLY on the final RTP packet of the access unit.
        XCTAssertEqual(packets.map(\.marker), [false, false, false, false, true])

        // Wire round-trip + FU-A depacketization must reconstruct exact original NAL units.
        var depacketizer = H264RTPDepacketizer()
        var reconstructed: [Data] = []
        for pkt in packets {
            let wire = pkt.serialize()
            XCTAssertLessThanOrEqual(wire.count, 1200, "Serialized RTP packet must stay within 1200-byte WebRTC MTU")
            guard let parsed = RTPPacket.parse(wire) else {
                XCTFail("Failed to parse serialized RTP packet")
                return
            }
            if let nalu = depacketizer.ingest(parsed) {
                reconstructed.append(nalu)
            }
        }

        XCTAssertEqual(reconstructed, [sps, pps, oversizedIDR])
    }

    // MARK: - 4. Text-First Congestion Frame Pacer

    func testAdaptiveFramePacerDropsCadenceBeforeCrushingTextBitrate() {
        var pacer = AdaptiveFramePacer(
            initialBitrateBps: 8_000_000,
            minTextCrispBitrateBps: 4_000_000,
            emergencyFloorBitrateBps: 1_500_000,
            baselineRTTMilliseconds: 30.0
        )

        // Moderate loss + RTT queue inflation: drop 60 -> 30 fps while keeping bitrate >= crisp-text floor.
        let step1 = pacer.ingest(TransportFeedbackSample(rttMilliseconds: 95.0, packetLossFraction: 0.03))
        XCTAssertEqual(step1.targetFPS, 30)
        XCTAssertGreaterThanOrEqual(step1.targetBitrateBps, 4_000_000)
        XCTAssertFalse(step1.requestImmediateKeyframe)

        // Severe packet loss spike (8%): drop cadence further and trigger PLI keyframe recovery.
        let step2 = pacer.ingest(TransportFeedbackSample(rttMilliseconds: 120.0, packetLossFraction: 0.08))
        XCTAssertEqual(step2.targetFPS, 12)
        XCTAssertGreaterThanOrEqual(step2.targetBitrateBps, 4_000_000)
        XCTAssertTrue(step2.requestImmediateKeyframe)

        // Healthy samples recover cadence step-by-step.
        var recovered = step2
        for _ in 0..<6 {
            recovered = pacer.ingest(TransportFeedbackSample(rttMilliseconds: 31.0, packetLossFraction: 0.0))
        }
        XCTAssertGreaterThan(recovered.targetFPS, 12)
    }

    // MARK: - 5. Binary DataChannel Control & Annotation Wire Codec

    func testControlChannelCodecBinaryRoundTrip() throws {
        let events: [ControlChannelEvent] = [
            .cursorMove(peerID: 7, normalizedX: 0.25, normalizedY: 0.75),
            .strokeBegin(
                strokeID: 9001,
                peerID: 7,
                color: .pairRose,
                lineWidthPoints: 4.0,
                normalizedX: 0.125,
                normalizedY: 0.625
            ),
            .strokePoint(strokeID: 9001, normalizedX: 0.5, normalizedY: 0.5),
            .strokeEnd(strokeID: 9001),
            .remoteMouse(button: .left, phase: .down, normalizedX: 0.8, normalizedY: 0.2),
            .remoteKey(virtualKeyCode: 36, modifierFlags: 0x0010_0000, isKeyDown: true)
        ]

        for event in events {
            let encoded = ControlChannelCodec.encode(event)
            let decoded = try ControlChannelCodec.decode(encoded)
            XCTAssertEqual(decoded, event)
        }
    }

    // MARK: - 6. Multi-Monitor AppKit <-> Quartz Coordinate Mapping & Ephemeral Stroke Decay

    func testMultiMonitorCoordinateMappingHandlesAppKitBottomLeftAndQuartzTopLeft() {
        // Secondary external display positioned above-right of a 1512x982 MacBook Pro primary screen.
        let secondaryDisplay = DisplaySpaceGeometry(
            appKitFramePoints: CGRect(x: 1512, y: 200, width: 2560, height: 1440),
            primaryDisplayHeightPoints: 982,
            backingScaleFactor: 2.0
        )

        // Top-left corner of secondary display (normalized 0, 0)
        let localTopLeft = secondaryDisplay.localAppKitViewPoint(normalizedX: 0.0, normalizedY: 0.0)
        XCTAssertEqual(localTopLeft.x, 0, accuracy: 0.001)
        XCTAssertEqual(localTopLeft.y, 1440, accuracy: 0.001)

        let globalAppKitTopLeft = secondaryDisplay.globalAppKitPoint(normalizedX: 0.0, normalizedY: 0.0)
        XCTAssertEqual(globalAppKitTopLeft.x, 1512, accuracy: 0.001)
        XCTAssertEqual(globalAppKitTopLeft.y, 1640, accuracy: 0.001)

        // In Quartz top-left coordinates (origin 0,0 at top-left of primary 982pt display),
        // y = 982 - 1640 = -658 (above primary screen's top edge).
        let quartzTopLeft = secondaryDisplay.globalQuartzEventPoint(normalizedX: 0.0, normalizedY: 0.0)
        XCTAssertEqual(quartzTopLeft.x, 1512, accuracy: 0.001)
        XCTAssertEqual(quartzTopLeft.y, -658, accuracy: 0.001)
    }

    func testAnnotationStrokeStoreDecaysAndPrunesCompletedCallouts() {
        var store = AnnotationStrokeStore(holdDurationSeconds: 1.0, fadeDurationSeconds: 1.0)
        store.apply(
            .strokeBegin(strokeID: 11, peerID: 2, color: .pairCyan, lineWidthPoints: 3.0, normalizedX: 0.2, normalizedY: 0.3),
            timestamp: 10.0
        )
        store.apply(.strokePoint(strokeID: 11, normalizedX: 0.4, normalizedY: 0.5), timestamp: 10.05)
        store.apply(.strokeEnd(strokeID: 11), timestamp: 10.10)

        // During hold window -> full opacity
        let duringHold = store.visibleStrokes(at: 10.80)
        XCTAssertEqual(duringHold.count, 1)
        XCTAssertEqual(duringHold[0].opacity, 1.0, accuracy: 0.001)

        // Mid-fade -> partial opacity
        let midFade = store.visibleStrokes(at: 11.60)
        XCTAssertEqual(midFade.count, 1)
        XCTAssertLessThan(midFade[0].opacity, 0.5)
        XCTAssertGreaterThan(midFade[0].opacity, 0.05)

        // Past fade duration -> pruned automatically
        let expired = store.visibleStrokes(at: 12.30)
        XCTAssertTrue(expired.isEmpty)
        XCTAssertEqual(store.activeStrokeCount, 0)
    }

    // MARK: - Helpers

    private static func makeTestPixelBuffer(width: Int, height: Int, seed: Int) throws -> CVPixelBuffer {
        var pixelBufferOut: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue as Any,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue as Any,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBufferOut
        )
        guard status == noErr, let buffer = pixelBufferOut else {
            throw NSError(domain: "ScreenLinkKitTests", code: Int(status))
        }

        _ = CVPixelBufferLockBaseAddress(buffer, [])
        defer { _ = CVPixelBufferUnlockBaseAddress(buffer, []) }

        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            let ptr = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                let row = ptr.advanced(by: y * bytesPerRow)
                let val = UInt8((y + seed * 17) & 0xFF)
                for x in 0..<width {
                    let o = x * 4
                    row[o + 0] = val
                    row[o + 1] = UInt8((x + seed * 9) & 0xFF)
                    row[o + 2] = 40
                    row[o + 3] = 255
                }
            }
        }
        return buffer
    }
}
