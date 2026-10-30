# ScreenLinkKit

[![macOS Build & Tests](https://github.com/ocakciomursel-pixel/ScreenLinkKit/actions/workflows/macos.yml/badge.svg)](https://github.com/ocakciomursel-pixel/ScreenLinkKit/actions/workflows/macos.yml)

Native macOS (Swift 5.10+, macOS 14+) building blocks for low-latency pair-programming screen sharing: compositor-level app privacy masking (`ScreenCaptureKit`), zero-B-frame hardware H.264 encoding (`VideoToolbox`), text-first congestion pacing, RFC 6184 RTP/DataChannel framing, and a non-activating click-through AppKit drawing overlay (`NSPanel`).

## Architecture & Design Choices

Screen sharing for code editors has fundamentally different constraints than webcam video:

1. **Compositor-Level App Masking (`AppMaskPolicy` + `ScreenCapturePipeline`)**
   - Uses `SCContentFilter(display:excludingApplications:exceptingWindows:)` so private windows (Messages, Slack, 1Password, Mail) are excluded by the macOS window server before pixels ever enter `CMSampleBuffer` memory.
   - Supports per-window exceptions (`exceptedWindowIDs`) and live hot-reloading via `SCStream.updateContentFilter(_:)` without dropping the active capture stream.
   - Filters `SCStreamFrameInfo.status` attachments to drop `.idle`, `.blank`, and `.suspended` keepalive frames prior to encoder submission, and extracts `SCStreamFrameInfo.dirtyRects` to distinguish static code reading from active scrolling.

2. **Zero-Reorder Hardware Encoding (`LowLatencyVideoEncoder`)**
   - Wraps `VTCompressionSession` with `kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder` and `kVTVideoEncoderSpecification_EnableLowLatencyRateControl` (falling back cleanly on virtualized CI runners without MediaEngine pass-through).
   - Disables B-frame reordering (`kVTCompressionPropertyKey_AllowFrameReordering = false`, `MaxFrameDelayCount = 0`) so frames emit strictly in presentation order with zero multi-frame decode buffering.
   - Caps 1-second burst rate (`kVTCompressionPropertyKey_DataRateLimits`) to avoid UDP socket buffer spikes on IDR keyframes and supports on-the-fly bitrate updates and PLI keyframe recovery.

3. **Text-First Congestion Adaptation (`AdaptiveFramePacer`)**
   - Standard webcam ABR crushes spatial quantization under packet loss, turning 11pt monospace editor fonts unreadable.
   - `AdaptiveFramePacer` keeps Retina spatial clarity above a crisp-text bitrate floor by stepping down capture cadence first (`60 -> 30 -> 20 -> 12 fps` via `SCStream.updateConfiguration`) when RTT inflates or packet loss exceeds 2%, recovering smoothly via AIMD.

4. **RFC 6184 RTP & Binary DataChannel Wire Protocol (`H264RTPPacketizer`, `ControlChannelCodec`)**
   - Fragments oversized H.264 NAL units via FU-A within a `1200`-byte WebRTC DTLS/SRTP MTU budget (`90 kHz` RTP media clock, 16-bit sequence wrap-around, Marker bit on access-unit boundary).
   - Encodes high-frequency (`120 Hz`) cursor movement, freehand annotation strokes, and remote mouse/keyboard input in fixed-size little-endian binary frames (`6–24` bytes) using display-normalized `[0.0, 1.0]` coordinates.

5. **Focus-Safe Multi-Monitor Drawing Overlay (`AnnotationOverlayWindow`, `DisplaySpaceGeometry`)**
   - Renders remote callouts inside a borderless `.nonactivatingPanel` with `ignoresMouseEvents = true` and `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`, allowing teammates to draw over full-screen Xcode or Terminal spaces without stealing keyboard focus or intercepting local clicks.
   - Smooths trackpad stroke points with quadratic midpoint splines, fades completed callouts out automatically, and handles the Y-origin inversion between AppKit (`bottom-left` global points) and `ScreenCaptureKit` / `CGEvent` (`top-left` Quartz global points) across mixed-DPI multi-display layouts.

## Layout

```text
Sources/
  ScreenLinkKit/
    Capture/
      AppMaskPolicy.swift           # Bundle-ID privacy masking & window exception filter
      ScreenCapturePipeline.swift   # SCStream lifecycle, idle-frame drop & dirtyRects extraction
    Encoding/
      LowLatencyVideoEncoder.swift  # Zero-B-frame VTCompressionSession H.264 encoder & AVCC extractor
    Transport/
      AdaptiveFramePacer.swift      # Text-first AIMD FPS/bitrate controller
      H264RTPPacketizer.swift       # RFC 6184 Single-NALU & FU-A packetizer / depacketizer
      ControlChannelCodec.swift     # Compact binary DataChannel codec for strokes & remote input
    Overlay/
      ScreenCoordinateMapper.swift  # Multi-monitor AppKit <-> Quartz mapper & stroke TTL decay store
      AnnotationOverlayWindow.swift # Non-activating click-through NSPanel vector drawing canvas
  ScreenLinkDemo/
    main.swift                      # 1080p60 encode + RTP benchmark & live desktop overlay demo
Tests/
  ScreenLinkKitTests/
    ScreenLinkKitTests.swift        # XCTest suite (VideoToolbox encode, RTP FU-A, pacer, coordinates)
```

## Build, Test & Benchmark

Requires macOS 14.0+ and Xcode 15.4+ / Swift 5.10+:

```bash
swift build -c release
swift test

# Run 1080p60 VideoToolbox + RFC 6184 RTP latency benchmark:
swift run -c release ScreenLinkDemo --benchmark --frames 60

# Preview live click-through NSPanel callout stroke on the primary display:
swift run ScreenLinkDemo --overlay-demo
```

## License

MIT
