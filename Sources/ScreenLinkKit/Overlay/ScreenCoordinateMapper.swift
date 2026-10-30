import CoreGraphics
import Foundation

/// Geometry snapshot of a macOS display across both AppKit (bottom-left global origin)
/// and Quartz / ScreenCaptureKit (top-left global origin) coordinate spaces.
public struct DisplaySpaceGeometry: Equatable, Sendable {
    /// Display frame in AppKit global screen points (`NSScreen.frame`, bottom-left origin on primary display).
    public let appKitFramePoints: CGRect
    /// Height of the primary display (`NSScreen.screens.first?.frame.height`), required to flip between AppKit and Quartz global Y.
    public let primaryDisplayHeightPoints: CGFloat
    public let backingScaleFactor: CGFloat

    public init(
        appKitFramePoints: CGRect,
        primaryDisplayHeightPoints: CGFloat,
        backingScaleFactor: CGFloat = 2.0
    ) {
        self.appKitFramePoints = appKitFramePoints
        self.primaryDisplayHeightPoints = primaryDisplayHeightPoints
        self.backingScaleFactor = max(1.0, backingScaleFactor)
    }

    /// Converts normalized `[0, 1]` top-left capture coordinates into local view points
    /// inside an AppKit `NSView` where `isFlipped == false` (bottom-left local origin).
    public func localAppKitViewPoint(normalizedX: Float, normalizedY: Float) -> CGPoint {
        let clampedX = CGFloat(min(1.0, max(0.0, normalizedX)))
        let clampedY = CGFloat(min(1.0, max(0.0, normalizedY)))
        return CGPoint(
            x: clampedX * appKitFramePoints.width,
            y: (1.0 - clampedY) * appKitFramePoints.height
        )
    }

    /// Converts normalized `[0, 1]` top-left capture coordinates into global AppKit screen points.
    public func globalAppKitPoint(normalizedX: Float, normalizedY: Float) -> CGPoint {
        let local = localAppKitViewPoint(normalizedX: normalizedX, normalizedY: normalizedY)
        return CGPoint(
            x: appKitFramePoints.origin.x + local.x,
            y: appKitFramePoints.origin.y + local.y
        )
    }

    /// Converts normalized `[0, 1]` top-left capture coordinates into Quartz global points
    /// suitable for `CGEvent(mouseEventSource:mouseType:mouseCursorPosition:mouseButton:)`.
    public func globalQuartzEventPoint(normalizedX: Float, normalizedY: Float) -> CGPoint {
        let globalAppKit = globalAppKitPoint(normalizedX: normalizedX, normalizedY: normalizedY)
        return CGPoint(
            x: globalAppKit.x,
            y: primaryDisplayHeightPoints - globalAppKit.y
        )
    }
}

/// Active or fading vector stroke drawn by a remote teammate.
public struct AnnotationStroke: Equatable, Sendable {
    public let strokeID: UInt32
    public let peerID: UInt16
    public let color: StrokeColor
    public let lineWidthPoints: CGFloat
    public private(set) var normalizedPoints: [CGPoint]
    public private(set) var completedAt: TimeInterval?

    public init(
        strokeID: UInt32,
        peerID: UInt16,
        color: StrokeColor,
        lineWidthPoints: CGFloat,
        initialPoint: CGPoint
    ) {
        self.strokeID = strokeID
        self.peerID = peerID
        self.color = color
        self.lineWidthPoints = max(1.5, lineWidthPoints)
        self.normalizedPoints = [initialPoint]
        self.completedAt = nil
    }

    public mutating func append(_ point: CGPoint) {
        normalizedPoints.append(point)
    }

    public mutating func markCompleted(at timestamp: TimeInterval) {
        if completedAt == nil {
            completedAt = timestamp
        }
    }

    /// Computes `[0.0, 1.0]` opacity for ephemeral callout fading after the teammate releases the pen.
    public func opacity(at now: TimeInterval, holdDuration: TimeInterval = 1.6, fadeDuration: TimeInterval = 1.2) -> CGFloat {
        guard let completedAt else { return 1.0 }
        let elapsed = now - completedAt
        if elapsed <= holdDuration { return 1.0 }
        let fadeElapsed = elapsed - holdDuration
        if fadeElapsed >= fadeDuration { return 0.0 }
        let linear = 1.0 - (fadeElapsed / max(0.05, fadeDuration))
        return CGFloat(linear * linear)
    }
}

/// Pure state container tracking active & decaying remote annotation strokes.
public struct AnnotationStrokeStore: Sendable {
    public var holdDurationSeconds: TimeInterval
    public var fadeDurationSeconds: TimeInterval
    private var strokesByID: [UInt32: AnnotationStroke] = [:]
    private var insertionOrder: [UInt32] = []

    public init(
        holdDurationSeconds: TimeInterval = 1.6,
        fadeDurationSeconds: TimeInterval = 1.2
    ) {
        self.holdDurationSeconds = holdDurationSeconds
        self.fadeDurationSeconds = fadeDurationSeconds
    }

    public var activeStrokeCount: Int {
        strokesByID.count
    }

    public mutating func apply(_ event: ControlChannelEvent, timestamp: TimeInterval) {
        switch event {
        case let .strokeBegin(strokeID, peerID, color, width, x, y):
            let stroke = AnnotationStroke(
                strokeID: strokeID,
                peerID: peerID,
                color: color,
                lineWidthPoints: CGFloat(width),
                initialPoint: CGPoint(x: CGFloat(x), y: CGFloat(y))
            )
            if strokesByID[strokeID] == nil {
                insertionOrder.append(strokeID)
            }
            strokesByID[strokeID] = stroke

        case let .strokePoint(strokeID, x, y):
            strokesByID[strokeID]?.append(CGPoint(x: CGFloat(x), y: CGFloat(y)))

        case let .strokeEnd(strokeID):
            strokesByID[strokeID]?.markCompleted(at: timestamp)

        case .cursorMove, .remoteMouse, .remoteKey:
            break
        }
    }

    /// Prunes fully decayed strokes and returns remaining visible strokes with their computed alpha.
    @discardableResult
    public mutating func visibleStrokes(at now: TimeInterval) -> [(stroke: AnnotationStroke, opacity: CGFloat)] {
        var visible: [(AnnotationStroke, CGFloat)] = []
        var aliveIDs: [UInt32] = []
        aliveIDs.reserveCapacity(insertionOrder.count)

        for id in insertionOrder {
            guard let stroke = strokesByID[id] else { continue }
            let alpha = stroke.opacity(
                at: now,
                holdDuration: holdDurationSeconds,
                fadeDuration: fadeDurationSeconds
            )
            if alpha > 0.005 {
                aliveIDs.append(id)
                visible.append((stroke, alpha))
            } else {
                strokesByID.removeValue(forKey: id)
            }
        }

        insertionOrder = aliveIDs
        return visible
    }
}
