import Foundation

/// Exact Apple Configurator evidence collected immediately before a generic
/// DFU erase-and-reinstall operation. This is independent of the reviewed
/// `SupportedDeviceCatalog`; it proves only that Apple's own tool agrees that
/// one exact iPhone is currently a restorable DFU target.
struct ConfiguratorDFURestoreInfo: Equatable {
    let ecid: String
    let productType: String
    let deviceClass: String
    let bootedState: String
    let isRestorable: Bool
    let locationID: Int

    func isExactRestorableDFU(for target: DFURestoreTarget) -> Bool {
        let normalizedClass = deviceClass
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedBootState = bootedState
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let isDFUBootState = normalizedBootState == "dfu" ||
            normalizedBootState.hasPrefix("dfu ") ||
            normalizedBootState.hasPrefix("dfu(")

        return isRestorable &&
            normalizedClass == "iphone" &&
            isDFUBootState &&
            IPhoneButtonFamily.classify(productType: productType) != nil &&
            DeviceDetector.normalizeECID(ecid) == DeviceDetector.normalizeECID(target.ecid) &&
            productType.caseInsensitiveCompare(target.productType) == .orderedSame &&
            locationID == target.locationID
    }
}

enum DFURestoreProof: String, Equatable, Hashable {
    /// Classic USB DFU, verified by targeted libirecovery mode and complete
    /// exact-ECID ProductType/HardwareModel/CPID/BDID evidence.
    case classicLibirecovery

    /// Newer KIS/Debug USB transport. This never claims classic DFU protocol;
    /// Apple Configurator is the destructive-grade restorable-target authority.
    case appleConfiguratorKIS
}

/// Destructive-grade identity pin for one generic iPhone erase-and-reinstall.
/// It deliberately does not grant Revive, Normal-iOS Factory Reset, utilities,
/// or custom-IPSW eligibility.
struct DFURestoreTarget: Equatable, Hashable {
    let ecid: String
    let locationID: Int
    let productType: String
    let hardwareModel: String?
    let chipID: UInt64?
    let boardID: UInt64?
    let proof: DFURestoreProof

    init?(snapshot: DeviceSnapshot) {
        guard snapshot.deviceCount == 1,
              !snapshot.identityConflict,
              let canonicalECID = DeviceDetector.canonicalECIDHex(snapshot.ecid),
              DeviceDetector.normalizeECID(canonicalECID) != "0",
              let locationID = snapshot.locationID,
              let productType = snapshot.productType,
              IPhoneButtonFamily.classify(productType: productType) != nil else {
            return nil
        }

        switch snapshot.usbPID {
        case 0x1227:
            guard snapshot.mode == .dfu,
                  snapshot.modeVerified,
                  snapshot.recoveryIdentityQueryTargetVerified,
                  let hardwareModel = Self.normalizedHardwareModel(snapshot.hardwareModel),
                  let chipID = Self.nonzeroIdentifier(snapshot.chipID),
                  let boardID = Self.nonzeroIdentifier(snapshot.boardID) else {
                return nil
            }
            self.ecid = canonicalECID
            self.locationID = locationID
            self.productType = productType
            self.hardwareModel = hardwareModel
            self.chipID = chipID
            self.boardID = boardID
            self.proof = .classicLibirecovery

        case 0x1881:
            guard snapshot.mode == .unknown || snapshot.mode == .dfu,
                  snapshot.configuratorDFURestoreVerified else {
                return nil
            }
            self.ecid = canonicalECID
            self.locationID = locationID
            self.productType = productType
            self.hardwareModel = Self.normalizedHardwareModel(snapshot.hardwareModel)
            self.chipID = Self.nonzeroIdentifier(snapshot.chipID)
            self.boardID = Self.nonzeroIdentifier(snapshot.boardID)
            self.proof = .appleConfiguratorKIS

        default:
            return nil
        }
    }

    var displayIdentity: String {
        if let hardwareModel {
            return "\(productType) / \(hardwareModel)"
        }
        return productType
    }

    var usesAppleLatestOnly: Bool { true }

    func matches(
        snapshot: DeviceSnapshot,
        configurator: ConfiguratorDFURestoreInfo
    ) -> Bool {
        guard let candidate = DFURestoreTarget(snapshot: snapshot),
              candidate == self else {
            return false
        }
        return configurator.isExactRestorableDFU(for: self)
    }

    private static func normalizedHardwareModel(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func nonzeroIdentifier(_ value: String?) -> UInt64? {
        guard let parsed = SupportedDeviceCatalog.numericIdentifier(value), parsed != 0 else {
            return nil
        }
        return parsed
    }
}

/// Identity retained across the disconnect/reboot caused by Restore. Generic
/// targets can prove that the same iPhone returned without becoming members of
/// the reviewed destructive hardware catalog.
struct RestorePostBootPin: Equatable {
    let ecid: String
    let productType: String
    let displayName: String
    let reviewedModel: SupportedDeviceModel?

    init?(
        ecid: String,
        productType: String,
        displayName: String? = nil,
        reviewedModel: SupportedDeviceModel? = nil
    ) {
        guard let canonicalECID = DeviceDetector.canonicalECIDHex(ecid),
              DeviceDetector.normalizeECID(canonicalECID) != "0",
              IPhoneButtonFamily.classify(productType: productType) != nil,
              reviewedModel == nil || reviewedModel?.productType == productType else {
            return nil
        }
        self.ecid = canonicalECID
        self.productType = productType
        let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = (trimmedName?.isEmpty == false ? trimmedName : nil) ?? productType
        self.reviewedModel = reviewedModel
    }

    init(target: DFURestoreTarget, displayName: String? = nil) {
        self.ecid = target.ecid
        self.productType = target.productType
        let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = (trimmedName?.isEmpty == false ? trimmedName : nil) ?? target.productType
        self.reviewedModel = nil
    }

    func matches(_ snapshot: DeviceSnapshot) -> Bool {
        guard snapshot.deviceCount == 1,
              snapshot.mode == .normal,
              snapshot.modeVerified,
              !snapshot.identityConflict,
              DeviceDetector.normalizeECID(snapshot.ecid) == DeviceDetector.normalizeECID(ecid),
              snapshot.productType?.caseInsensitiveCompare(productType) == .orderedSame else {
            return false
        }
        if let reviewedModel {
            return snapshot.hasVerifiedSupportedDeviceIdentity &&
                snapshot.supportedDeviceModel == reviewedModel
        }
        return IPhoneButtonFamily.classify(productType: snapshot.productType) != nil
    }
}

/// Pure policy used by the destructive confirmation dialog. The ECID suffix
/// binds typed consent to the target that was displayed to the user.
struct DestructiveRestoreConfirmationPolicy: Equatable {
    let phrase: String

    init?(ecid: String) {
        guard let canonical = DeviceDetector.canonicalECIDHex(ecid),
              DeviceDetector.normalizeECID(canonical) != "0" else {
            return nil
        }
        let digits = canonical.dropFirst(2).suffix(6).uppercased()
        guard !digits.isEmpty else { return nil }
        phrase = "ERASE \(digits)"
    }

    func accepts(typedText: String, dataLossAcknowledged: Bool) -> Bool {
        dataLossAcknowledged && typedText == phrase
    }
}
