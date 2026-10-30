import AppKit
import CoreGraphics
import Foundation

/// Non-activating, click-through `NSPanel` overlay rendered above full-screen workspaces
/// so remote pair-programming annotations never steal keyboard focus or intercept local clicks.
@MainActor
public final class AnnotationOverlayWindow: NSPanel {
    private let canvasView: AnnotationCanvasView

    public init(screen: NSScreen) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let geometry = DisplaySpaceGeometry(
            appKitFramePoints: screen.frame,
            primaryDisplayHeightPoints: primaryHeight,
            backingScaleFactor: screen.backingScaleFactor
        )
        self.canvasView = AnnotationCanvasView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            geometry: geometry
        )

        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .screenSaver
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = true
        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false
        self.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        self.contentView = canvasView
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    /// Ingests an incoming DataChannel event and schedules a 60 Hz fade pass if needed.
    public func ingest(_ event: ControlChannelEvent, timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        canvasView.ingest(event, timestamp: timestamp)
    }

    /// Re-anchors the click-through overlay when display resolution or arrangement changes.
    public func attach(to screen: NSScreen) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let geometry = DisplaySpaceGeometry(
            appKitFramePoints: screen.frame,
            primaryDisplayHeightPoints: primaryHeight,
            backingScaleFactor: screen.backingScaleFactor
        )
        setFrame(screen.frame, display: true)
        canvasView.updateGeometry(geometry)
    }
}

@MainActor
public final class AnnotationCanvasView: NSView {
    private var geometry: DisplaySpaceGeometry
    private var strokeStore = AnnotationStrokeStore()
    private var remoteCursors: [UInt16: CGPoint] = [:]
    private var fadeTimer: Timer?

    public init(frame frameRect: NSRect, geometry: DisplaySpaceGeometry) {
        self.geometry = geometry
        super.init(frame: frameRect)
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public func updateGeometry(_ newGeometry: DisplaySpaceGeometry) {
        self.geometry = newGeometry
        self.frame = NSRect(origin: .zero, size: newGeometry.appKitFramePoints.size)
        needsDisplay = true
    }

    public func ingest(_ event: ControlChannelEvent, timestamp: TimeInterval) {
        if case let .cursorMove(peerID, x, y) = event {
            remoteCursors[peerID] = geometry.localAppKitViewPoint(normalizedX: x, normalizedY: y)
        } else {
            strokeStore.apply(event, timestamp: timestamp)
        }
        ensureAnimationTimerRunning()
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let visible = strokeStore.visibleStrokes(at: now)

        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for (stroke, opacity) in visible {
            let mappedPoints = stroke.normalizedPoints.map { pt in
                geometry.localAppKitViewPoint(normalizedX: Float(pt.x), normalizedY: Float(pt.y))
            }
            guard let first = mappedPoints.first else { continue }

            let cgColor = CGColor(
                srgbRed: CGFloat(stroke.color.r) / 255.0,
                green: CGFloat(stroke.color.g) / 255.0,
                blue: CGFloat(stroke.color.b) / 255.0,
                alpha: (CGFloat(stroke.color.a) / 255.0) * opacity
            )
            context.setStrokeColor(cgColor)
            context.setLineWidth(stroke.lineWidthPoints)

            let path = CGMutablePath()
            path.move(to: first)

            if mappedPoints.count == 1 {
                path.addLine(to: CGPoint(x: first.x + 0.5, y: first.y + 0.5))
            } else if mappedPoints.count == 2 {
                path.addLine(to: mappedPoints[1])
            } else {
                // Smooth freehand trackpad input via quadratic midpoint splines.
                for idx in 1..<(mappedPoints.count - 1) {
                    let current = mappedPoints[idx]
                    let next = mappedPoints[idx + 1]
                    let mid = CGPoint(x: (current.x + next.x) * 0.5, y: (current.y + next.y) * 0.5)
                    path.addQuadCurve(to: mid, control: current)
                }
                if let last = mappedPoints.last {
                    path.addLine(to: last)
                }
            }

            context.addPath(path)
            context.strokePath()
        }

        // Render lightweight remote peer cursor rings.
        for (_, cursorPoint) in remoteCursors {
            let ringRect = CGRect(x: cursorPoint.x - 6, y: cursorPoint.y - 6, width: 12, height: 12)
            context.setStrokeColor(CGColor(srgbRed: 0.96, green: 0.25, blue: 0.37, alpha: 0.9))
            context.setLineWidth(2.0)
            context.strokeEllipse(in: ringRect)
        }

        context.restoreGState()

        if visible.isEmpty && fadeTimer != nil {
            fadeTimer?.invalidate()
            fadeTimer = nil
        }
    }

    private func ensureAnimationTimerRunning() {
        guard fadeTimer == nil else { return }
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.needsDisplay = true
            }
        }
    }
}
