import Foundation

/// Network feedback snapshot derived from RTCP Receiver Reports / TWCC feedback.
public struct TransportFeedbackSample: Equatable, Sendable {
    public let rttMilliseconds: Double
    public let packetLossFraction: Double
    public let hasActiveScreenMotion: Bool

    public init(
        rttMilliseconds: Double,
        packetLossFraction: Double,
        hasActiveScreenMotion: Bool = true
    ) {
        self.rttMilliseconds = max(0, rttMilliseconds)
        self.packetLossFraction = min(1.0, max(0.0, packetLossFraction))
        self.hasActiveScreenMotion = hasActiveScreenMotion
    }
}

/// Target capture & encoder pacing parameters emitted by `AdaptiveFramePacer`.
public struct PacingDecision: Equatable, Sendable {
    public let targetFPS: Int
    public let targetBitrateBps: Int
    public let requestImmediateKeyframe: Bool

    public init(targetFPS: Int, targetBitrateBps: Int, requestImmediateKeyframe: Bool) {
        self.targetFPS = targetFPS
        self.targetBitrateBps = targetBitrateBps
        self.requestImmediateKeyframe = requestImmediateKeyframe
    }
}

/// Text-first AIMD congestion pacer tailored for pair-programming screen sharing.
///
/// Unlike webcam ABR—which aggressively degrades spatial quantization and blurs 11pt editor text—
/// `AdaptiveFramePacer` preserves spatial crispness by stepping down frame cadence first
/// (`60 -> 30 -> 20 -> 12 fps`) when loss or RTT spikes, only reducing bitrate below the
/// crisp-text floor under sustained congestion.
public struct AdaptiveFramePacer: Sendable {
    private static let cadenceLadder: [Int] = [12, 20, 30, 60]

    public let minTextCrispBitrateBps: Int
    public let emergencyFloorBitrateBps: Int
    public let maxBitrateBps: Int
    public let baselineRTTMilliseconds: Double

    private var cadenceIndex: Int
    private var currentBitrateBps: Int
    private var consecutiveHealthySamples: Int = 0

    public init(
        initialBitrateBps: Int = 8_000_000,
        minTextCrispBitrateBps: Int = 4_000_000,
        emergencyFloorBitrateBps: Int = 1_500_000,
        maxBitrateBps: Int = 14_000_000,
        baselineRTTMilliseconds: Double = 35.0
    ) {
        self.minTextCrispBitrateBps = minTextCrispBitrateBps
        self.emergencyFloorBitrateBps = emergencyFloorBitrateBps
        self.maxBitrateBps = maxBitrateBps
        self.baselineRTTMilliseconds = max(5.0, baselineRTTMilliseconds)
        self.cadenceIndex = Self.cadenceLadder.count - 1
        self.currentBitrateBps = min(maxBitrateBps, max(emergencyFloorBitrateBps, initialBitrateBps))
    }

    public var currentDecision: PacingDecision {
        PacingDecision(
            targetFPS: Self.cadenceLadder[cadenceIndex],
            targetBitrateBps: currentBitrateBps,
            requestImmediateKeyframe: false
        )
    }

    public mutating func ingest(_ sample: TransportFeedbackSample) -> PacingDecision {
        let severeLoss = sample.packetLossFraction >= 0.06
        let moderateLoss = sample.packetLossFraction >= 0.02
        let queueInflation = sample.rttMilliseconds > (baselineRTTMilliseconds * 2.4)

        if severeLoss || (moderateLoss && queueInflation) {
            consecutiveHealthySamples = 0
            // Step 1: Drop frame cadence before sacrificing spatial text sharpness.
            if cadenceIndex > 0 {
                cadenceIndex = max(0, cadenceIndex - (severeLoss ? 2 : 1))
                currentBitrateBps = max(minTextCrispBitrateBps, Int(Double(currentBitrateBps) * 0.85))
            } else {
                // Already at 12 fps minimum cadence; step down toward emergency bitrate floor.
                currentBitrateBps = max(emergencyFloorBitrateBps, Int(Double(currentBitrateBps) * 0.75))
            }
            return PacingDecision(
                targetFPS: Self.cadenceLadder[cadenceIndex],
                targetBitrateBps: currentBitrateBps,
                requestImmediateKeyframe: severeLoss
            )
        }

        if moderateLoss || queueInflation {
            consecutiveHealthySamples = 0
            if cadenceIndex > 1 {
                cadenceIndex -= 1
            } else {
                currentBitrateBps = max(minTextCrispBitrateBps, Int(Double(currentBitrateBps) * 0.90))
            }
            return PacingDecision(
                targetFPS: Self.cadenceLadder[cadenceIndex],
                targetBitrateBps: currentBitrateBps,
                requestImmediateKeyframe: false
            )
        }

        // Healthy network window: additive recovery of spatial bitrate first, then frame cadence.
        consecutiveHealthySamples += 1
        if consecutiveHealthySamples >= 3 {
            if currentBitrateBps < minTextCrispBitrateBps {
                currentBitrateBps = min(minTextCrispBitrateBps, currentBitrateBps + 600_000)
            } else if cadenceIndex < Self.cadenceLadder.count - 1 {
                cadenceIndex += 1
                consecutiveHealthySamples = 0
            } else if sample.hasActiveScreenMotion {
                currentBitrateBps = min(maxBitrateBps, currentBitrateBps + 500_000)
            }
        }

        let effectiveFPS = sample.hasActiveScreenMotion
            ? Self.cadenceLadder[cadenceIndex]
            : min(20, Self.cadenceLadder[cadenceIndex])

        return PacingDecision(
            targetFPS: effectiveFPS,
            targetBitrateBps: currentBitrateBps,
            requestImmediateKeyframe: false
        )
    }
}
