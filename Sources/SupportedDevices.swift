import Foundation

/// One exact Apple hardware identity supported by YIOS-KIT recovery workflows.
/// Normal-iOS writes require the exact ProductType; every additional identity
/// field that is present must agree with this row. Recovery/DFU writes require
/// the complete ProductType/HardwareModel/CPID/BDID tuple.
struct SupportedDeviceModel: Equatable, Hashable {
    let productType: String
    let hardwareModel: String
    let chipID: UInt64
    let boardID: UInt64
    let marketingName: String

    var identitySummary: String {
        "\(marketingName) • \(productType) / \(hardwareModel)"
    }
}

enum SupportedDeviceCatalog {
    /// Explicitly bounded to iPhone 8 through iPhone SE (2nd generation).
    /// Never replace this table with a ProductType prefix or numeric range.
    static let all: [SupportedDeviceModel] = [
        SupportedDeviceModel(productType: "iPhone10,1", hardwareModel: "d20ap", chipID: 0x8015, boardID: 0x02, marketingName: "iPhone 8 (Global)"),
        SupportedDeviceModel(productType: "iPhone10,2", hardwareModel: "d21ap", chipID: 0x8015, boardID: 0x04, marketingName: "iPhone 8 Plus (Global)"),
        SupportedDeviceModel(productType: "iPhone10,3", hardwareModel: "d22ap", chipID: 0x8015, boardID: 0x06, marketingName: "iPhone X (Global)"),
        SupportedDeviceModel(productType: "iPhone10,4", hardwareModel: "d201ap", chipID: 0x8015, boardID: 0x0A, marketingName: "iPhone 8 (GSM)"),
        SupportedDeviceModel(productType: "iPhone10,5", hardwareModel: "d211ap", chipID: 0x8015, boardID: 0x0C, marketingName: "iPhone 8 Plus (GSM)"),
        SupportedDeviceModel(productType: "iPhone10,6", hardwareModel: "d221ap", chipID: 0x8015, boardID: 0x0E, marketingName: "iPhone X (GSM)"),
        SupportedDeviceModel(productType: "iPhone11,2", hardwareModel: "d321ap", chipID: 0x8020, boardID: 0x0E, marketingName: "iPhone XS"),
        SupportedDeviceModel(productType: "iPhone11,4", hardwareModel: "d331ap", chipID: 0x8020, boardID: 0x0A, marketingName: "iPhone XS Max (China)"),
        SupportedDeviceModel(productType: "iPhone11,6", hardwareModel: "d331pap", chipID: 0x8020, boardID: 0x1A, marketingName: "iPhone XS Max"),
        SupportedDeviceModel(productType: "iPhone11,8", hardwareModel: "n841ap", chipID: 0x8020, boardID: 0x0C, marketingName: "iPhone XR"),
        SupportedDeviceModel(productType: "iPhone12,1", hardwareModel: "n104ap", chipID: 0x8030, boardID: 0x04, marketingName: "iPhone 11"),
        SupportedDeviceModel(productType: "iPhone12,3", hardwareModel: "d421ap", chipID: 0x8030, boardID: 0x06, marketingName: "iPhone 11 Pro"),
        SupportedDeviceModel(productType: "iPhone12,5", hardwareModel: "d431ap", chipID: 0x8030, boardID: 0x02, marketingName: "iPhone 11 Pro Max"),
        SupportedDeviceModel(productType: "iPhone12,8", hardwareModel: "d79ap", chipID: 0x8030, boardID: 0x10, marketingName: "iPhone SE (2nd generation)")
    ]

    static let se2 = all.first { $0.productType == "iPhone12,8" }!
    static let productTypes = Set(all.map(\.productType))
    static let hardwareModels = Set(all.map { $0.hardwareModel.lowercased() })

    static func model(productType: String?) -> SupportedDeviceModel? {
        guard let productType = normalizedProductType(productType) else { return nil }
        return all.first { $0.productType.caseInsensitiveCompare(productType) == .orderedSame }
    }

    static func model(hardwareModel: String?) -> SupportedDeviceModel? {
        guard let hardwareModel = normalizedHardwareModel(hardwareModel) else { return nil }
        return all.first { $0.hardwareModel.lowercased() == hardwareModel }
    }

    /// Returns a model only when all identity evidence that is present agrees
    /// with one exact registry row. Conflicting or unknown evidence fails closed.
    static func model(
        productType: String?,
        hardwareModel: String?,
        chipID: String? = nil,
        boardID: String? = nil
    ) -> SupportedDeviceModel? {
        let normalizedProduct = normalizedProductType(productType)
        let normalizedHardware = normalizedHardwareModel(hardwareModel)
        let productCandidate = model(productType: normalizedProduct)
        let hardwareCandidate = model(hardwareModel: normalizedHardware)

        let candidate: SupportedDeviceModel
        switch (normalizedProduct, normalizedHardware) {
        case (.some, .some):
            guard let productCandidate, let hardwareCandidate,
                  productCandidate == hardwareCandidate else { return nil }
            candidate = productCandidate
        case (.some, .none):
            guard let productCandidate else { return nil }
            candidate = productCandidate
        case (.none, .some):
            guard let hardwareCandidate else { return nil }
            candidate = hardwareCandidate
        case (.none, .none):
            return nil
        }

        if chipID != nil {
            guard numericIdentifier(chipID) == candidate.chipID else { return nil }
        }
        if boardID != nil {
            guard numericIdentifier(boardID) == candidate.boardID else { return nil }
        }
        return candidate
    }

    static func marketingName(for productType: String?) -> String? {
        model(productType: productType)?.marketingName
    }

    static func isExactSE2(
        productType: String?,
        hardwareModel: String?,
        chipID: String? = nil,
        boardID: String? = nil
    ) -> Bool {
        model(
            productType: productType,
            hardwareModel: hardwareModel,
            chipID: chipID,
            boardID: boardID
        ) == se2
    }

    static func normalizedProductType(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func normalizedHardwareModel(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    static func numericIdentifier(_ value: String?) -> UInt64? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("0x") {
            return UInt64(trimmed.dropFirst(2), radix: 16)
        }
        if trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "abcdef")) != nil {
            return UInt64(trimmed, radix: 16)
        }
        return UInt64(trimmed, radix: 10)
    }
}

extension DeviceSnapshot {
    /// A partial identity is useful for display, but never sufficient by itself
    /// to authorize a recovery write.
    var supportedDeviceModel: SupportedDeviceModel? {
        guard !identityConflict else { return nil }
        return SupportedDeviceCatalog.model(
            productType: productType,
            hardwareModel: hardwareModel,
            chipID: chipID,
            boardID: boardID
        )
    }

    /// Write-capable identity: verified Normal iOS requires exact ProductType;
    /// other available fields are consistency evidence. Recovery/DFU require
    /// the complete ProductType/HardwareModel/CPID/BDID libirecovery tuple.
    var hasVerifiedSupportedDeviceIdentity: Bool {
        guard !identityConflict, productType != nil,
              supportedDeviceModel != nil else { return false }
        if mode == .recovery || mode == .dfu {
            return recoveryIdentityQueryVerified && hardwareModel != nil &&
                chipID != nil && boardID != nil
        }
        return true
    }

    var supportedDeviceDisplayName: String {
        supportedDeviceModel?.marketingName
            ?? SupportedDeviceCatalog.marketingName(for: productType)
            ?? marketingName
            ?? productType
            ?? "supported iPhone"
    }
}
