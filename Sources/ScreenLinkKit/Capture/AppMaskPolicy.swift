import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Value descriptor representing a shareable running application on macOS.
/// Decouples policy evaluation from TCC-gated `SCShareableContent` instances in unit tests.
public struct RunningAppDescriptor: Equatable, Hashable, Sendable {
    public let bundleIdentifier: String
    public let applicationName: String
    public let processID: pid_t

    public init(bundleIdentifier: String, applicationName: String, processID: pid_t) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.processID = processID
    }

    public init(_ app: SCRunningApplication) {
        self.bundleIdentifier = app.bundleIdentifier
        self.applicationName = app.applicationName
        self.processID = app.processID
    }
}

/// Value descriptor representing an on-screen window candidate.
public struct WindowDescriptor: Equatable, Hashable, Sendable {
    public let windowID: CGWindowID
    public let owningBundleIdentifier: String?
    public let title: String?
    public let isOnScreen: Bool

    public init(
        windowID: CGWindowID,
        owningBundleIdentifier: String?,
        title: String?,
        isOnScreen: Bool = true
    ) {
        self.windowID = windowID
        self.owningBundleIdentifier = owningBundleIdentifier
        self.title = title
        self.isOnScreen = isOnScreen
    }

    public init(_ window: SCWindow) {
        self.windowID = window.windowID
        self.owningBundleIdentifier = window.owningApplication?.bundleIdentifier
        self.title = window.title
        self.isOnScreen = window.isOnScreen
    }
}

/// Privacy masking policy for full-display screen sharing.
///
/// Excludes sensitive communication, credential, and mail apps from `SCContentFilter`
/// at the compositor level so masked windows never enter the `CMSampleBuffer` stream,
/// while optionally keeping explicitly excepted window IDs visible.
public struct AppMaskPolicy: Equatable, Sendable {
    public static let defaultMaskedBundleIdentifiers: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.apple.MobileSMS",
        "com.apple.Passwords",
        "com.apple.mail",
        "com.bitwarden.desktop",
        "com.tinyspeck.slackmacgap",
        "org.whispersystems.signal-desktop",
        "ru.keepcoder.Telegram"
    ]

    public var excludedBundleIdentifiers: Set<String>
    public var exceptedWindowIDs: Set<CGWindowID>

    public init(
        excludedBundleIdentifiers: Set<String> = AppMaskPolicy.defaultMaskedBundleIdentifiers,
        exceptedWindowIDs: Set<CGWindowID> = []
    ) {
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
        self.exceptedWindowIDs = exceptedWindowIDs
    }

    /// Evaluates which applications must be excluded and which individual windows
    /// should be passed to `SCContentFilter(display:excludingApplications:exceptingWindows:)`.
    public func evaluate(
        applications: [RunningAppDescriptor],
        windows: [WindowDescriptor]
    ) -> (excludedApps: [RunningAppDescriptor], exceptedWindows: [WindowDescriptor]) {
        let normalizedExcluded = Set(excludedBundleIdentifiers.map { $0.lowercased() })

        let excludedApps = applications.filter { app in
            normalizedExcluded.contains(app.bundleIdentifier.lowercased())
        }

        let exceptedWindows = windows.filter { window in
            window.isOnScreen && exceptedWindowIDs.contains(window.windowID)
        }

        return (excludedApps, exceptedWindows)
    }

    /// Builds a compositor-level `SCContentFilter` for a target `SCDisplay`.
    public func makeContentFilter(
        display: SCDisplay,
        shareableContent: SCShareableContent,
        additionalExcludedWindowIDs: Set<CGWindowID> = []
    ) -> SCContentFilter {
        let normalizedExcluded = Set(excludedBundleIdentifiers.map { $0.lowercased() })

        let excludedApps = shareableContent.applications.filter { app in
            normalizedExcluded.contains(app.bundleIdentifier.lowercased())
        }

        let effectiveExceptedIDs = exceptedWindowIDs.subtracting(additionalExcludedWindowIDs)
        let exceptedWindows = shareableContent.windows.filter { window in
            effectiveExceptedIDs.contains(window.windowID)
        }

        return SCContentFilter(
            display: display,
            excludingApplications: excludedApps,
            exceptingWindows: exceptedWindows
        )
    }
}
