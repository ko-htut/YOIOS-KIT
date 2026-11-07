import Foundation

/// Physical-button layout used only for Recovery/DFU guidance. This is kept
/// separate from `SupportedDeviceCatalog`: recognizing a button family never
/// authorizes Restore, Revive, erase, or firmware selection.
enum IPhoneButtonFamily: String, Equatable, Hashable {
    case homeButton
    case iPhone7
    case modern

    static func classify(productType: String?) -> IPhoneButtonFamily? {
        guard let productType else { return nil }
        let pattern = #"^iPhone([1-9][0-9]*),(0|[1-9][0-9]*)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: productType,
                range: NSRange(productType.startIndex..., in: productType)
              ),
              match.range == NSRange(productType.startIndex..., in: productType),
              let majorRange = Range(match.range(at: 1), in: productType),
              let major = Int(productType[majorRange]) else {
            return nil
        }

        switch major {
        case 1...8: return .homeButton
        case 9: return .iPhone7
        default: return .modern
        }
    }

    var displayName: String {
        switch self {
        case .homeButton: return "Home-button iPhone"
        case .iPhone7: return "iPhone 7 / 7 Plus"
        case .modern: return "iPhone 8 or later"
        }
    }

    var recoverySteps: [String] {
        switch self {
        case .homeButton:
            return [
                "Keep the iPhone connected to the Mac.",
                "Press and hold the Home button and the Side (or Top) button together.",
                "Keep holding both buttons through the Apple logo.",
                "Release only when the Connect-to-computer screen appears."
            ]
        case .iPhone7:
            return [
                "Keep the iPhone connected to the Mac.",
                "Press and hold the Side button and Volume Down together.",
                "Keep holding both buttons through the Apple logo.",
                "Release only when the Connect-to-computer screen appears."
            ]
        case .modern:
            return [
                "Keep the iPhone connected to the Mac.",
                "Quick-press Volume Up.",
                "Quick-press Volume Down.",
                "Hold the Side button through the black screen and Apple logo. Release only when the Connect-to-computer screen appears."
            ]
        }
    }

    /// Timings are guidance for a person pressing physical buttons. They are
    /// never treated as proof that DFU was reached.
    var dfuSteps: [String] {
        switch self {
        case .homeButton:
            return [
                "Physical buttons are required. Keep the cable connected and turn the iPhone off if possible.",
                "Hold Home and the Side (or Top) button together for about 8 seconds.",
                "Release the Side (or Top) button, but keep holding Home for about 10 seconds.",
                "Release when YIOS-KIT verifies DFU over USB. The display must stay black."
            ]
        case .iPhone7:
            return [
                "Physical buttons are required. Keep the cable connected and turn the iPhone off if possible.",
                "Hold Side and Volume Down together for about 8 seconds.",
                "Release Side, but keep holding Volume Down for about 10 seconds.",
                "Release when YIOS-KIT verifies DFU over USB. The display must stay black."
            ]
        case .modern:
            return [
                "Physical buttons are required. Quick-press Volume Up, quick-press Volume Down, then hold Side until the display turns black.",
                "As soon as the display is black, hold Side and Volume Down together for about 5 seconds.",
                "Release Side, but keep holding Volume Down for about 10 seconds.",
                "Release when YIOS-KIT verifies DFU over USB. The display must stay black."
            ]
        }
    }
}

/// Exact, non-destructive Normal-iOS target for a software Recovery request.
/// It deliberately accepts syntactically valid iPhones outside the reviewed
/// destructive catalog.
struct RecoveryTransitionTarget: Equatable, Hashable {
    let ecid: String
    let udid: String
    let locationID: Int
    let productType: String
    let buttonFamily: IPhoneButtonFamily

    init?(snapshot: DeviceSnapshot) {
        guard snapshot.deviceCount == 1,
              snapshot.mode == .normal,
              snapshot.modeVerified,
              !snapshot.identityConflict,
              let ecid = DeviceDetector.canonicalECIDHex(snapshot.ecid),
              DeviceDetector.normalizeECID(ecid) != "0",
              let udid = snapshot.udid,
              !udid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let locationID = snapshot.locationID,
              let productType = snapshot.productType,
              let buttonFamily = IPhoneButtonFamily.classify(productType: productType) else {
            return nil
        }
        self.ecid = ecid
        self.udid = udid
        self.locationID = locationID
        self.productType = productType
        self.buttonFamily = buttonFamily
    }

    func matches(_ snapshot: DeviceSnapshot) -> Bool {
        guard let candidate = RecoveryTransitionTarget(snapshot: snapshot) else {
            return false
        }
        return DeviceDetector.normalizeECID(candidate.ecid) == DeviceDetector.normalizeECID(ecid) &&
            candidate.udid.caseInsensitiveCompare(udid) == .orderedSame &&
            candidate.locationID == locationID &&
            candidate.productType == productType &&
            candidate.buttonFamily == buttonFamily
    }
}

enum RecoveryTransitionStage: Int, Equatable {
    case firstFreshCheck = 1
    case finalFreshCheck = 2
}

struct RecoveryTransitionDependencies {
    let detect: () -> DeviceSnapshot
    let validatePairing: (String) -> PairingValidation
    let run: (String, [String], TimeInterval) -> CommandResult
    let hasCompetingClient: () -> Bool
}

enum RecoveryTransitionExecutionResult {
    case succeeded(latest: DeviceSnapshot, command: CommandResult)
    case targetChanged(latest: DeviceSnapshot, stage: RecoveryTransitionStage)
    case pairingFailed(latest: DeviceSnapshot, stage: RecoveryTransitionStage, detail: String)
    case competingClient(latest: DeviceSnapshot, stage: RecoveryTransitionStage)
    case commandFailed(latest: DeviceSnapshot, command: CommandResult)
}

/// Synchronous, deterministic executor. The caller owns queueing/UI state and
/// supplies a resolved executable path. This function never shells out through
/// a command string and never retries the one Recovery request.
enum RecoveryTransitionExecutor {
    static let commandTimeout: TimeInterval = 30

    static func execute(
        tool: String,
        target: RecoveryTransitionTarget,
        dependencies: RecoveryTransitionDependencies
    ) -> RecoveryTransitionExecutionResult {
        let first = dependencies.detect()
        guard target.matches(first) else {
            return .targetChanged(latest: first, stage: .firstFreshCheck)
        }
        let firstPairing = dependencies.validatePairing(target.udid)
        guard firstPairing.isValid else {
            return .pairingFailed(
                latest: first,
                stage: .firstFreshCheck,
                detail: firstPairing.detail
            )
        }
        guard !dependencies.hasCompetingClient() else {
            return .competingClient(latest: first, stage: .firstFreshCheck)
        }

        let final = dependencies.detect()
        guard target.matches(final) else {
            return .targetChanged(latest: final, stage: .finalFreshCheck)
        }
        let finalPairing = dependencies.validatePairing(target.udid)
        guard finalPairing.isValid else {
            return .pairingFailed(
                latest: final,
                stage: .finalFreshCheck,
                detail: finalPairing.detail
            )
        }
        guard !dependencies.hasCompetingClient() else {
            return .competingClient(latest: final, stage: .finalFreshCheck)
        }

        let command = dependencies.run(
            tool,
            [target.udid],
            commandTimeout
        )
        if command.exitCode == 0, !command.timedOut {
            return .succeeded(latest: final, command: command)
        }
        return .commandFailed(latest: final, command: command)
    }
}
