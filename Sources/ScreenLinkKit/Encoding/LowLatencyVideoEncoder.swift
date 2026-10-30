import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Output access unit emitted by `LowLatencyVideoEncoder`.
public struct EncodedVideoFrame: Equatable, Sendable {
    public let presentationTimestamp: CMTime
    public let isKeyframe: Bool
    /// Raw H.264 NAL units (without Annex-B start codes or AVCC length prefixes),
    /// ordered with SPS/PPS first on keyframes followed by VCL slice NALUs.
    public let nalUnits: [Data]
    public let encodeDurationMicroseconds: UInt64

    public init(
        presentationTimestamp: CMTime,
        isKeyframe: Bool,
        nalUnits: [Data],
        encodeDurationMicroseconds: UInt64
    ) {
        self.presentationTimestamp = presentationTimestamp
        self.isKeyframe = isKeyframe
        self.nalUnits = nalUnits
        self.encodeDurationMicroseconds = encodeDurationMicroseconds
    }

    public var totalPayloadBytes: Int {
        nalUnits.reduce(0) { $0 + $1.count }
    }
}

/// Configuration tuned specifically for low-latency desktop & IDE screen sharing.
public struct VideoEncoderConfiguration: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var averageBitrateBps: Int
    public var expectedFPS: Int
    public var maxKeyframeIntervalSeconds: Int

    public init(
        width: Int,
        height: Int,
        averageBitrateBps: Int = 8_000_000,
        expectedFPS: Int = 60,
        maxKeyframeIntervalSeconds: Int = 4
    ) {
        self.width = width
        self.height = height
        self.averageBitrateBps = max(250_000, averageBitrateBps)
        self.expectedFPS = max(1, expectedFPS)
        self.maxKeyframeIntervalSeconds = max(1, maxKeyframeIntervalSeconds)
    }
}

public enum VideoEncoderError: Error, LocalizedError {
    case sessionCreationFailed(OSStatus)
    case prepareToEncodeFailed(OSStatus)
    case encodeFailed(OSStatus)
    case sessionClosed

    public var errorDescription: String? {
        switch self {
        case .sessionCreationFailed(let status):
            return "VTCompressionSessionCreate failed with OSStatus \(status)."
        case .prepareToEncodeFailed(let status):
            return "VTCompressionSessionPrepareToEncodeFrames failed with OSStatus \(status)."
        case .encodeFailed(let status):
            return "VTCompressionSessionEncodeFrame failed with OSStatus \(status)."
        case .sessionClosed:
            return "Video encoder session is closed."
        }
    }
}

private final class FrameTimingToken {
    let dispatchTimeNanoseconds: UInt64

    init(dispatchTimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        self.dispatchTimeNanoseconds = dispatchTimeNanoseconds
    }
}

/// Hardware-accelerated `VTCompressionSession` H.264 encoder configured for interactive
/// screen sharing: zero B-frames (`AllowFrameReordering = false`), real-time rate control,
/// tight burst caps, and dynamic PLI keyframe / bitrate adaptation.
public final class LowLatencyVideoEncoder {
    public typealias OutputHandler = (EncodedVideoFrame) -> Void

    private var session: VTCompressionSession?
    private var configuration: VideoEncoderConfiguration
    private let lock = NSLock()
    private var forceNextKeyframe = true

    public var onEncodedFrame: OutputHandler?
    public private(set) var isHardwareAccelerated: Bool = false

    public init(configuration: VideoEncoderConfiguration) throws {
        self.configuration = configuration
        try createCompressionSession(for: configuration)
    }

    deinit {
        invalidate()
    }

    public func requestKeyframe() {
        lock.withLock {
            forceNextKeyframe = true
        }
    }

    /// Updates target bitrate on the fly in response to transport congestion feedback.
    public func updateTargetBitrate(_ bitrateBps: Int) {
        let clamped = max(250_000, bitrateBps)
        let activeSession: VTCompressionSession? = lock.withLock {
            configuration.averageBitrateBps = clamped
            return session
        }
        guard let activeSession else { return }

        _ = VTSessionSetProperty(
            activeSession,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: NSNumber(value: clamped)
        )
        // Limit 1-second burst window to 1.5x target bitrate to prevent UDP socket buffer bloat on IDR frames.
        let byteLimitPerSecond = Int(Double(clamped) / 8.0 * 1.5)
        let limits: [NSNumber] = [NSNumber(value: byteLimitPerSecond), NSNumber(value: 1.0)]
        _ = VTSessionSetProperty(
            activeSession,
            key: kVTCompressionPropertyKey_DataRateLimits,
            value: limits as CFArray
        )
    }

    /// Submits a `CVImageBuffer` for immediate zero-reorder encoding.
    public func encode(
        pixelBuffer: CVImageBuffer,
        presentationTimestamp: CMTime,
        duration: CMTime = .invalid,
        forceKeyframe: Bool = false
    ) throws {
        let (activeSession, shouldForceKeyframe): (VTCompressionSession, Bool) = try lock.withLock {
            guard let session else { throw VideoEncoderError.sessionClosed }
            let emitIDR = forceKeyframe || forceNextKeyframe
            forceNextKeyframe = false
            return (session, emitIDR)
        }

        var frameProps: CFDictionary?
        if shouldForceKeyframe {
            let dict: [CFString: Any] = [
                kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue as Any
            ]
            frameProps = dict as CFDictionary
        }

        let token = FrameTimingToken()
        let sourceRefcon = Unmanaged.passRetained(token).toOpaque()
        var infoFlags: VTEncodeInfoFlags = []

        let status = VTCompressionSessionEncodeFrame(
            activeSession,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTimestamp,
            duration: duration,
            frameProperties: frameProps,
            sourceFrameRefcon: sourceRefcon,
            infoFlagsOut: &infoFlags
        )

        if status != noErr {
            Unmanaged<FrameTimingToken>.fromOpaque(sourceRefcon).release()
            throw VideoEncoderError.encodeFailed(status)
        }
    }

    /// Blocks until all in-flight frames have been emitted to `onEncodedFrame`.
    public func flush() {
        let activeSession: VTCompressionSession? = lock.withLock { session }
        guard let activeSession else { return }
        _ = VTCompressionSessionCompleteFrames(activeSession, untilPresentationTimeStamp: .invalid)
    }

    public func invalidate() {
        let existing: VTCompressionSession? = lock.withLock {
            let current = session
            session = nil
            return current
        }
        if let existing {
            VTCompressionSessionInvalidate(existing)
        }
    }

    // MARK: - Private Setup & Callback

    private func createCompressionSession(for config: VideoEncoderConfiguration) throws {
        let hwSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: kCFBooleanTrue as Any,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue as Any
        ]

        let pixelAttrs: [CFString: Any] = [
            kCVPixelBufferWidthKey: NSNumber(value: config.width),
            kCVPixelBufferHeightKey: NSNumber(value: config.height),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]

        var createdSession: VTCompressionSession?
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        var status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(config.width),
            height: Int32(config.height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: hwSpec as CFDictionary,
            imageBufferAttributes: pixelAttrs as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: Self.compressionCallback,
            refcon: selfPtr,
            compressionSessionOut: &createdSession
        )

        // Fallback gracefully on virtualized macOS runners where MediaEngine low-latency rate control is unavailable.
        if status != noErr || createdSession == nil {
            createdSession = nil
            status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: Int32(config.width),
                height: Int32(config.height),
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: nil,
                imageBufferAttributes: pixelAttrs as CFDictionary,
                compressedDataAllocator: nil,
                outputCallback: Self.compressionCallback,
                refcon: selfPtr,
                compressionSessionOut: &createdSession
            )
        }

        guard status == noErr, let activeSession = createdSession else {
            throw VideoEncoderError.sessionCreationFailed(status)
        }

        // Core low-latency properties: real-time mode, zero B-frames, zero frame-delay buffering.
        _ = VTSessionSetProperty(activeSession, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        _ = VTSessionSetProperty(activeSession, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        _ = VTSessionSetProperty(activeSession, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        _ = VTSessionSetProperty(activeSession, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: NSNumber(value: 0))
        _ = VTSessionSetProperty(activeSession, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: config.expectedFPS))
        _ = VTSessionSetProperty(
            activeSession,
            key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: NSNumber(value: config.expectedFPS * config.maxKeyframeIntervalSeconds)
        )
        _ = VTSessionSetProperty(
            activeSession,
            key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            value: NSNumber(value: config.maxKeyframeIntervalSeconds)
        )
        _ = VTSessionSetProperty(
            activeSession,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: NSNumber(value: config.averageBitrateBps)
        )

        let byteLimitPerSecond = Int(Double(config.averageBitrateBps) / 8.0 * 1.5)
        let limits: [NSNumber] = [NSNumber(value: byteLimitPerSecond), NSNumber(value: 1.0)]
        _ = VTSessionSetProperty(
            activeSession,
            key: kVTCompressionPropertyKey_DataRateLimits,
            value: limits as CFArray
        )

        var rawBoolPtr: Unmanaged<CFBoolean>?
        let copyPropStatus = withUnsafeMutablePointer(to: &rawBoolPtr) { ptr in
            VTSessionCopyProperty(
                activeSession,
                key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                allocator: kCFAllocatorDefault,
                valueOut: UnsafeMutableRawPointer(ptr)
            )
        }
        if copyPropStatus == noErr, let cfBool = rawBoolPtr?.takeRetainedValue() {
            self.isHardwareAccelerated = CFBooleanGetValue(cfBool)
        }

        let prepStatus = VTCompressionSessionPrepareToEncodeFrames(activeSession)
        guard prepStatus == noErr else {
            VTCompressionSessionInvalidate(activeSession)
            throw VideoEncoderError.prepareToEncodeFailed(prepStatus)
        }

        self.session = activeSession
    }

    private static let compressionCallback: VTCompressionOutputCallback = {
        outputCallbackRefCon, sourceFrameRefCon, status, infoFlags, sampleBuffer in
        let elapsedMicros: UInt64
        if let sourceFrameRefCon {
            let token = Unmanaged<FrameTimingToken>.fromOpaque(sourceFrameRefCon).takeRetainedValue()
            let now = DispatchTime.now().uptimeNanoseconds
            elapsedMicros = now >= token.dispatchTimeNanoseconds
                ? (now - token.dispatchTimeNanoseconds) / 1_000
                : 0
        } else {
            elapsedMicros = 0
        }

        guard status == noErr,
              !infoFlags.contains(.frameDropped),
              let outputCallbackRefCon,
              let sampleBuffer,
              CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }

        let encoder = Unmanaged<LowLatencyVideoEncoder>.fromOpaque(outputCallbackRefCon).takeUnretainedValue()
        encoder.handleCompressedSampleBuffer(sampleBuffer, encodeDurationMicroseconds: elapsedMicros)
    }

    private func handleCompressedSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        encodeDurationMicroseconds: UInt64
    ) {
        let keyframe = Self.isSyncSample(sampleBuffer)
        var nalUnits: [Data] = []

        if keyframe, let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            nalUnits.append(contentsOf: Self.extractH264ParameterSets(from: formatDesc))
        }

        if let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
            nalUnits.append(contentsOf: Self.extractAVCCNALUnits(from: dataBuffer))
        }

        guard !nalUnits.isEmpty else { return }

        let frame = EncodedVideoFrame(
            presentationTimestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            isKeyframe: keyframe,
            nalUnits: nalUnits,
            encodeDurationMicroseconds: encodeDurationMicroseconds
        )
        onEncodedFrame?(frame)
    }

    private static func isSyncSample(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [NSDictionary],
        let first = attachments.first else {
            return true
        }
        let notSync = (first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
        return !notSync
    }

    private static func extractH264ParameterSets(from formatDescription: CMFormatDescription) -> [Data] {
        var count: Int = 0
        var headerLength: Int32 = 0
        let countStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: &headerLength
        )
        guard countStatus == noErr, count > 0 else { return [] }

        var sets: [Data] = []
        sets.reserveCapacity(count)

        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size: Int = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )
            if status == noErr, let pointer, size > 0 {
                sets.append(Data(bytes: pointer, count: size))
            }
        }
        return sets
    }

    private static func extractAVCCNALUnits(from blockBuffer: CMBlockBuffer) -> [Data] {
        let totalLength = CMBlockBufferGetDataLength(blockBuffer)
        guard totalLength > 4 else { return [] }

        var contiguousBytes = [UInt8](repeating: 0, count: totalLength)
        let copyStatus = contiguousBytes.withUnsafeMutableBytes { rawBuffer -> OSStatus in
            guard let baseAddress = rawBuffer.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: totalLength,
                destination: baseAddress
            )
        }
        guard copyStatus == noErr else { return [] }

        var units: [Data] = []
        var offset = 0
        while offset + 4 <= totalLength {
            let nalLength =
                (Int(contiguousBytes[offset]) << 24) |
                (Int(contiguousBytes[offset + 1]) << 16) |
                (Int(contiguousBytes[offset + 2]) << 8) |
                Int(contiguousBytes[offset + 3])
            offset += 4

            guard nalLength > 0, offset + nalLength <= totalLength else {
                break
            }
            units.append(Data(contiguousBytes[offset..<(offset + nalLength)]))
            offset += nalLength
        }
        return units
    }
}
