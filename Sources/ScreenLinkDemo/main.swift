import AppKit
import CoreMedia
import CoreVideo
import Foundation
import ScreenLinkKit

enum DemoMode {
    case benchmark(frameCount: Int)
    case overlayPreview
}

func parseArguments() -> DemoMode {
    let args = CommandLine.arguments
    if args.contains("--overlay-demo") {
        return .overlayPreview
    }
    var frames = 60
    if let idx = args.firstIndex(of: "--frames"), idx + 1 < args.count, let parsed = Int(args[idx + 1]) {
        frames = max(5, min(600, parsed))
    }
    return .benchmark(frameCount: frames)
}

func makeSyntheticEditorFrame(width: Int, height: Int, frameIndex: Int) throws -> CVPixelBuffer {
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
        throw NSError(domain: "ScreenLinkDemo", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "CVPixelBufferCreate failed"])
    }

    _ = CVPixelBufferLockBaseAddress(buffer, [])
    defer { _ = CVPixelBufferUnlockBaseAddress(buffer, []) }

    guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return buffer }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    let rawPtr = baseAddress.assumingMemoryBound(to: UInt8.self)

    let activeHighlightY = (frameIndex * 18) % max(1, height - 36)

    for y in 0..<height {
        let row = rawPtr.advanced(by: y * bytesPerRow)
        let isCodeLine = (y % 22) < 9 && y > 48
        let isHighlightBand = y >= activeHighlightY && y < (activeHighlightY + 24)

        for x in 0..<width {
            let offset = x * 4
            if x < 64 {
                // Editor gutter
                row[offset + 0] = 30
                row[offset + 1] = 27
                row[offset + 2] = 26
                row[offset + 3] = 255
            } else if isCodeLine && x > 88 && x < (280 + ((y * 13) % 720)) {
                // Simulated high-contrast syntax tokens (sharp vertical edges stress chroma/QP)
                let tokenColor = (x / 48) % 3
                row[offset + 0] = tokenColor == 0 ? 235 : 130
                row[offset + 1] = tokenColor == 1 ? 210 : 175
                row[offset + 2] = tokenColor == 2 ? 245 : 120
                row[offset + 3] = 255
            } else if isHighlightBand {
                row[offset + 0] = 52
                row[offset + 1] = 42
                row[offset + 2] = 38
                row[offset + 3] = 255
            } else {
                row[offset + 0] = 24
                row[offset + 1] = 22
                row[offset + 2] = 20
                row[offset + 3] = 255
            }
        }
    }

    return buffer
}

func percentile(_ sorted: [UInt64], _ p: Double) -> UInt64 {
    guard !sorted.isEmpty else { return 0 }
    let idx = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
    return sorted[idx]
}

func runBenchmark(frameCount: Int) throws {
    let width = 1920
    let height = 1080
    let fps = 60

    let encoderConfig = VideoEncoderConfiguration(
        width: width,
        height: height,
        averageBitrateBps: 8_000_000,
        expectedFPS: fps,
        maxKeyframeIntervalSeconds: 2
    )
    let encoder = try LowLatencyVideoEncoder(configuration: encoderConfig)

    var packetizer = H264RTPPacketizer(maxPayloadBytes: 1188)
    var depacketizer = H264RTPDepacketizer()
    let lock = NSLock()

    var encodeLatenciesMicros: [UInt64] = []
    var totalEncodedBytes = 0
    var totalPackets = 0
    var reassembledNALCount = 0
    var keyframeCount = 0

    encoder.onEncodedFrame = { frame in
        let rtpTS = H264RTPPacketizer.rtpTimestamp(for: frame.presentationTimestamp)
        lock.withLock {
            encodeLatenciesMicros.append(frame.encodeDurationMicroseconds)
            totalEncodedBytes += frame.totalPayloadBytes
            if frame.isKeyframe { keyframeCount += 1 }

            let packets = packetizer.packetize(nalUnits: frame.nalUnits, rtpTimestamp: rtpTS)
            totalPackets += packets.count
            for pkt in packets {
                if depacketizer.ingest(pkt) != nil {
                    reassembledNALCount += 1
                }
            }
        }
    }

    for index in 0..<frameCount {
        let pixelBuffer = try makeSyntheticEditorFrame(width: width, height: height, frameIndex: index)
        let pts = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))
        let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
        try encoder.encode(
            pixelBuffer: pixelBuffer,
            presentationTimestamp: pts,
            duration: duration,
            forceKeyframe: index == 0
        )
    }
    encoder.flush()

    let sorted = encodeLatenciesMicros.sorted()
    let p50Ms = Double(percentile(sorted, 0.50)) / 1000.0
    let p95Ms = Double(percentile(sorted, 0.95)) / 1000.0
    let maxMs = Double(sorted.last ?? 0) / 1000.0
    let simulatedSeconds = Double(frameCount) / Double(fps)
    let effectiveMbps = simulatedSeconds > 0
        ? (Double(totalEncodedBytes * 8) / simulatedSeconds) / 1_000_000.0
        : 0

    print("ScreenLinkKit Low-Latency Media Pipeline Benchmark")
    print("--------------------------------------------------")
    print("Resolution          : \(width)x\(height) @ \(fps) fps (zero B-frames)")
    print("Hardware Encoder    : \(encoder.isHardwareAccelerated ? "Yes (VideoToolbox MediaEngine)" : "Software fallback (VM)")")
    print("Frames Encoded      : \(sorted.count)/\(frameCount) (IDR keyframes: \(keyframeCount))")
    print(String(format: "Encode Latency      : p50 = %.2f ms | p95 = %.2f ms | max = %.2f ms", p50Ms, p95Ms, maxMs))
    print("RTP Packets Emitted : \(totalPackets) (MTU payload cap 1188 B, reassembled NALUs: \(reassembledNALCount))")
    print(String(format: "Effective Bitrate   : %.2f Mbps", effectiveMbps))
}

@MainActor
func runOverlayPreview() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    guard let screen = NSScreen.main else {
        print("No active NSScreen available for overlay preview.")
        return
    }

    let overlay = AnnotationOverlayWindow(screen: screen)
    overlay.orderFrontRegardless()

    let now = ProcessInfo.processInfo.systemUptime
    overlay.ingest(
        .strokeBegin(
            strokeID: 1,
            peerID: 42,
            color: .pairRose,
            lineWidthPoints: 4.5,
            normalizedX: 0.35,
            normalizedY: 0.40
        ),
        timestamp: now
    )

    let steps = 36
    for i in 1...steps {
        let angle = (Double(i) / Double(steps)) * (2.0 * Double.pi)
        let nx = Float(0.45 + 0.10 * cos(angle))
        let ny = Float(0.45 + 0.08 * sin(angle))
        overlay.ingest(.strokePoint(strokeID: 1, normalizedX: nx, normalizedY: ny), timestamp: now + Double(i) * 0.01)
    }
    overlay.ingest(.strokeEnd(strokeID: 1), timestamp: now + 0.4)

    DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
        overlay.close()
        app.terminate(nil)
    }
    app.run()
}

do {
    switch parseArguments() {
    case .benchmark(let frames):
        try runBenchmark(frameCount: frames)
    case .overlayPreview:
        MainActor.assumeIsolated {
            runOverlayPreview()
        }
    }
} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
