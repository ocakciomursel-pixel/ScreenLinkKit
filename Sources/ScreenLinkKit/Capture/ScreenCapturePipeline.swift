import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// Configuration for `ScreenCapturePipeline`.
public struct CaptureConfiguration: Equatable, Sendable {
    public var targetFPS: Int
    public var backingScaleFactor: Double
    public var queueDepth: Int
    public var showsCursor: Bool
    public var pixelFormat: OSType

    public init(
        targetFPS: Int = 60,
        backingScaleFactor: Double = 2.0,
        queueDepth: Int = 3,
        showsCursor: Bool = true,
        pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    ) {
        self.targetFPS = max(1, min(120, targetFPS))
        self.backingScaleFactor = max(1.0, backingScaleFactor)
        self.queueDepth = max(1, min(8, queueDepth))
        self.showsCursor = showsCursor
        self.pixelFormat = pixelFormat
    }

    public func makeStreamConfiguration(for display: SCDisplay) -> SCStreamConfiguration {
        let streamConfig = SCStreamConfiguration()
        streamConfig.width = Int((Double(display.width) * backingScaleFactor).rounded())
        streamConfig.height = Int((Double(display.height) * backingScaleFactor).rounded())
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
        streamConfig.queueDepth = queueDepth
        streamConfig.showsCursor = showsCursor
        streamConfig.scalesToFit = false
        streamConfig.pixelFormat = pixelFormat
        streamConfig.colorSpaceName = CGColorSpace.sRGB
        return streamConfig
    }
}

/// Extracted per-frame compositor metadata from `ScreenCaptureKit` sample attachments.
public struct CapturedFrameMetadata: Equatable, Sendable {
    public let presentationTimestamp: CMTime
    public let dirtyRects: [CGRect]
    public let contentScale: Double
    public let hasPixelUpdates: Bool

    public init(
        presentationTimestamp: CMTime,
        dirtyRects: [CGRect],
        contentScale: Double,
        hasPixelUpdates: Bool
    ) {
        self.presentationTimestamp = presentationTimestamp
        self.dirtyRects = dirtyRects
        self.contentScale = contentScale
        self.hasPixelUpdates = hasPixelUpdates
    }
}

/// Coordinates low-latency `SCStream` display capture, `AppMaskPolicy` live updates,
/// and `SCStreamFrameInfo` idle/dirty-region filtering before hardware encoding.
public final class ScreenCapturePipeline: NSObject, SCStreamDelegate, SCStreamOutput {
    public typealias FrameHandler = (CVImageBuffer, CapturedFrameMetadata) -> Void
    public typealias ErrorHandler = (Error) -> Void

    private let captureQueue = DispatchQueue(
        label: "app.screenlinkkit.capture.sample-output",
        qos: .userInteractive
    )
    private let stateLock = NSLock()

    private var stream: SCStream?
    private var activeDisplay: SCDisplay?
    private var configuration: CaptureConfiguration
    private var maskPolicy: AppMaskPolicy

    public var onFrame: FrameHandler?
    public var onStreamError: ErrorHandler?

    public init(
        configuration: CaptureConfiguration = CaptureConfiguration(),
        maskPolicy: AppMaskPolicy = AppMaskPolicy()
    ) {
        self.configuration = configuration
        self.maskPolicy = maskPolicy
        super.init()
    }

    /// Starts capturing the specified display (or primary display when `displayID == nil`).
    public func start(
        displayID: CGDirectDisplayID? = nil,
        excludedOverlayWindowIDs: Set<CGWindowID> = []
    ) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let targetID = displayID ?? CGMainDisplayID()

        guard let display = content.displays.first(where: { $0.displayID == targetID }) ?? content.displays.first else {
            throw NSError(
                domain: "ScreenLinkKit.Capture",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No shareable macOS display found."]
            )
        }

        let currentConfig: CaptureConfiguration = stateLock.withLock { configuration }
        let currentPolicy: AppMaskPolicy = stateLock.withLock { maskPolicy }

        let filter = currentPolicy.makeContentFilter(
            display: display,
            shareableContent: content,
            additionalExcludedWindowIDs: excludedOverlayWindowIDs
        )
        let streamConfig = currentConfig.makeStreamConfiguration(for: display)

        let newStream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try await newStream.startCapture()

        stateLock.withLock {
            self.activeDisplay = display
            self.stream = newStream
        }
    }

    /// Dynamically updates target FPS without tearing down the `SCStream` session.
    /// Used by `AdaptiveFramePacer` to reduce frame cadence under packet loss while keeping 1:1 Retina text clarity.
    public func updateTargetFPS(_ fps: Int) async throws {
        let clamped = max(1, min(120, fps))
        let snapshot: (SCStream, SCDisplay, CaptureConfiguration)? = stateLock.withLock {
            configuration.targetFPS = clamped
            guard let stream, let activeDisplay else { return nil }
            return (stream, activeDisplay, configuration)
        }

        guard let (activeStream, display, updatedConfig) = snapshot else { return }
        let streamConfig = updatedConfig.makeStreamConfiguration(for: display)
        try await activeStream.updateConfiguration(streamConfig)
    }

    /// Hot-reloads the compositor app-mask filter while sharing remains live.
    public func updateMaskPolicy(
        _ newPolicy: AppMaskPolicy,
        excludedOverlayWindowIDs: Set<CGWindowID> = []
    ) async throws {
        let snapshot: (SCStream, SCDisplay)? = stateLock.withLock {
            self.maskPolicy = newPolicy
            guard let stream, let activeDisplay else { return nil }
            return (stream, activeDisplay)
        }

        guard let (activeStream, display) = snapshot else { return }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let filter = newPolicy.makeContentFilter(
            display: display,
            shareableContent: content,
            additionalExcludedWindowIDs: excludedOverlayWindowIDs
        )
        try await activeStream.updateContentFilter(filter)
    }

    public func stop() async {
        let currentStream: SCStream? = stateLock.withLock {
            let existing = stream
            stream = nil
            activeDisplay = nil
            return existing
        }
        guard let currentStream else { return }
        try? await currentStream.stopCapture()
    }

    // MARK: - SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onStreamError?(error)
    }

    // MARK: - SCStreamOutput

    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }

        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [NSDictionary],
        let attachments = attachmentsArray.first else {
            return
        }

        // Drop compositor keepalive frames (.idle / .blank / .suspended) before hitting VideoToolbox.
        if let rawStatus = (attachments[SCStreamFrameInfo.status.rawValue] as? NSNumber)?.intValue,
           let status = SCFrameStatus(rawValue: rawStatus),
           status != .complete {
            return
        }

        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let scale = (attachments[SCStreamFrameInfo.scaleFactor.rawValue] as? NSNumber)?.doubleValue ?? 1.0
        var dirtyRects: [CGRect] = []
        if let rawRects = attachments[SCStreamFrameInfo.dirtyRects.rawValue] as? [NSDictionary] {
            dirtyRects.reserveCapacity(rawRects.count)
            for dict in rawRects {
                if let rect = CGRect(dictionaryRepresentation: dict as CFDictionary), !rect.isEmpty {
                    dirtyRects.append(rect)
                }
            }
        }

        let metadata = CapturedFrameMetadata(
            presentationTimestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            dirtyRects: dirtyRects,
            contentScale: scale,
            hasPixelUpdates: !dirtyRects.isEmpty
        )
        onFrame?(imageBuffer, metadata)
    }
}
