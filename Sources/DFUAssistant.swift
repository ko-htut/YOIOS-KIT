import Foundation

/// Describes what a passive USB watcher is allowed to accept. The watcher
/// never starts a restore, sends a recovery command, or infers success from a
/// black screen or elapsed time.
enum USBMonitorIntent: Equatable {
    case recoveryOrDFU
    case dfuOnly
}

/// User-visible lifecycle for the DFU timing assistant. Detection and final
/// identity verification remain distinct so a raw USB observation can never
/// be presented as a verified DFU result.
enum DFUAssistantState: Equatable {
    case idle
    case monitoring
    case missedRecovery
    case verifying
    case verified
    case verificationFailed
    case observedKISUnverified
    case timedOut
    case cancelled
}

enum DFUAssistantStatePolicy {
    static func reconciled(
        current: DFUAssistantState,
        previous: DeviceSnapshot,
        detected: DeviceSnapshot,
        isMonitoring: Bool,
        hasPendingVerification: Bool
    ) -> DFUAssistantState {
        guard !isMonitoring, !hasPendingVerification else { return current }
        let targetChanged = DeviceDetector.normalizeECID(previous.ecid) !=
            DeviceDetector.normalizeECID(detected.ecid)
        let modeChanged = previous.mode != detected.mode
        return targetChanged || modeChanged ? .idle : current
    }
}

enum USBMonitorEvent: Equatable {
    case none
    case recoveryOrDFUCandidate(DeviceMode)
    case dfuCandidate
    case missedRecovery
    case observedKISUnverified
}

/// Identity boundary between a stable raw DFU USB observation and a user-
/// visible verified result. This policy is intentionally independent of the
/// destructive model catalog: it can verify that an unsupported iPhone is the
/// pinned classic-DFU target without granting any other device capability.
struct DFUVerificationPin: Equatable {
    let ecid: String
    let locationID: Int?
    let productType: String?

    init?(ecid: String, locationID: Int?, productType: String?) {
        guard let canonicalECID = DeviceDetector.canonicalECIDHex(ecid),
              DeviceDetector.normalizeECID(canonicalECID) != "0" else {
            return nil
        }
        if let productType,
           IPhoneButtonFamily.classify(productType: productType) == nil {
            return nil
        }
        self.ecid = canonicalECID
        self.locationID = locationID
        self.productType = productType
    }

    func matches(_ snapshot: DeviceSnapshot) -> Bool {
        guard snapshot.deviceCount == 1,
              snapshot.mode == .dfu,
              snapshot.usbPID == 0x1227,
              snapshot.modeVerified,
              !snapshot.identityConflict,
              DeviceDetector.normalizeECID(snapshot.ecid) == DeviceDetector.normalizeECID(ecid),
              IPhoneButtonFamily.classify(productType: snapshot.productType) != nil else {
            return false
        }
        if let locationID, snapshot.locationID != locationID { return false }
        if let productType,
           snapshot.productType?.caseInsensitiveCompare(productType) != .orderedSame {
            return false
        }
        return true
    }
}

/// Raw KIS observation pinned before the slower Apple Configurator scan.
/// This prevents a replacement phone from satisfying the assistant result.
struct KISVerificationPin: Equatable {
    let ecid: String
    let locationID: Int?
    let productType: String?

    init?(ecid: String, locationID: Int?, productType: String?) {
        guard let canonicalECID = DeviceDetector.canonicalECIDHex(ecid),
              DeviceDetector.normalizeECID(canonicalECID) != "0" else {
            return nil
        }
        if let productType,
           IPhoneButtonFamily.classify(productType: productType) == nil {
            return nil
        }
        self.ecid = canonicalECID
        self.locationID = locationID
        self.productType = productType
    }

    func matches(_ target: DFURestoreTarget) -> Bool {
        guard target.proof == .appleConfiguratorKIS,
              DeviceDetector.normalizeECID(target.ecid) == DeviceDetector.normalizeECID(ecid) else {
            return false
        }
        if let locationID, target.locationID != locationID { return false }
        if let productType,
           target.productType.caseInsensitiveCompare(productType) != .orderedSame {
            return false
        }
        return true
    }
}

/// Reduces raw, repeated USB samples into stable transition candidates for one
/// exact ECID and (when known) one USB location. This type intentionally owns
/// no timer and launches no process, which keeps its safety behavior testable
/// without an attached iPhone.
struct DFUMonitorTracker {
    let pinnedECID: String
    let pinnedLocation: Int?
    let intent: USBMonitorIntent
    let requiredStableSamples: Int

    private var candidateMode: DeviceMode?
    private var candidateCount = 0
    private var recoveryCount = 0
    private var recoveryReported = false
    private var kisReported = false

    init(
        pinnedECID: String,
        pinnedLocation: Int?,
        intent: USBMonitorIntent,
        requiredStableSamples: Int = 5
    ) {
        self.pinnedECID = pinnedECID
        self.pinnedLocation = pinnedLocation
        self.intent = intent
        self.requiredStableSamples = max(1, requiredStableSamples)
    }

    mutating func observe(_ snapshot: DeviceSnapshot) -> USBMonitorEvent {
        guard matchesPinnedTarget(snapshot) else {
            resetStability()
            return .none
        }

        // Some newer devices expose KIS/Debug USB as PID 0x1881 during the
        // path toward DFU. The classic verification pin cannot attest that
        // transport; the caller must perform a separate exact Configurator
        // restorable-target scan before presenting it as eligible.
        if snapshot.usbPID == 0x1881 {
            candidateMode = nil
            candidateCount = 0
            recoveryCount = 0
            recoveryReported = false
            guard !kisReported else { return .none }
            kisReported = true
            return .observedKISUnverified
        }
        kisReported = false

        switch intent {
        case .recoveryOrDFU:
            recoveryCount = 0
            recoveryReported = false
            guard snapshot.mode == .recovery || snapshot.mode == .dfu else {
                candidateMode = nil
                candidateCount = 0
                return .none
            }
            if candidateMode == snapshot.mode {
                candidateCount += 1
            } else {
                candidateMode = snapshot.mode
                candidateCount = 1
            }
            guard candidateCount >= requiredStableSamples else { return .none }
            return .recoveryOrDFUCandidate(snapshot.mode)

        case .dfuOnly:
            if snapshot.mode == .dfu {
                recoveryCount = 0
                recoveryReported = false
                if candidateMode == .dfu {
                    candidateCount += 1
                } else {
                    candidateMode = .dfu
                    candidateCount = 1
                }
                guard candidateCount >= requiredStableSamples else { return .none }
                return .dfuCandidate
            }

            candidateMode = nil
            candidateCount = 0
            guard snapshot.mode == .recovery else {
                recoveryCount = 0
                recoveryReported = false
                return .none
            }
            recoveryCount += 1
            guard recoveryCount >= requiredStableSamples,
                  !recoveryReported else { return .none }
            recoveryReported = true
            return .missedRecovery
        }
    }

    private func matchesPinnedTarget(_ snapshot: DeviceSnapshot) -> Bool {
        guard snapshot.deviceCount == 1,
              DeviceDetector.normalizeECID(snapshot.ecid) ==
                DeviceDetector.normalizeECID(pinnedECID) else {
            return false
        }
        if let pinnedLocation {
            return snapshot.locationID == pinnedLocation
        }
        return true
    }

    private mutating func resetStability() {
        candidateMode = nil
        candidateCount = 0
        recoveryCount = 0
        recoveryReported = false
        kisReported = false
    }
}
