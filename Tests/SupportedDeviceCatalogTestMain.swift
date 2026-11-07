import Foundation

@main
struct SupportedDeviceCatalogTestMain {
    private struct ExpectedRow {
        let productType: String
        let hardwareModel: String
        let chipID: UInt64
        let boardID: UInt64
        let marketingName: String

        var model: SupportedDeviceModel {
            SupportedDeviceModel(
                productType: productType,
                hardwareModel: hardwareModel,
                chipID: chipID,
                boardID: boardID,
                marketingName: marketingName
            )
        }
    }

    private static let expectedRows = [
        ExpectedRow(productType: "iPhone10,1", hardwareModel: "d20ap", chipID: 0x8015, boardID: 0x02, marketingName: "iPhone 8 (Global)"),
        ExpectedRow(productType: "iPhone10,2", hardwareModel: "d21ap", chipID: 0x8015, boardID: 0x04, marketingName: "iPhone 8 Plus (Global)"),
        ExpectedRow(productType: "iPhone10,3", hardwareModel: "d22ap", chipID: 0x8015, boardID: 0x06, marketingName: "iPhone X (Global)"),
        ExpectedRow(productType: "iPhone10,4", hardwareModel: "d201ap", chipID: 0x8015, boardID: 0x0A, marketingName: "iPhone 8 (GSM)"),
        ExpectedRow(productType: "iPhone10,5", hardwareModel: "d211ap", chipID: 0x8015, boardID: 0x0C, marketingName: "iPhone 8 Plus (GSM)"),
        ExpectedRow(productType: "iPhone10,6", hardwareModel: "d221ap", chipID: 0x8015, boardID: 0x0E, marketingName: "iPhone X (GSM)"),
        ExpectedRow(productType: "iPhone11,2", hardwareModel: "d321ap", chipID: 0x8020, boardID: 0x0E, marketingName: "iPhone XS"),
        ExpectedRow(productType: "iPhone11,4", hardwareModel: "d331ap", chipID: 0x8020, boardID: 0x0A, marketingName: "iPhone XS Max (China)"),
        ExpectedRow(productType: "iPhone11,6", hardwareModel: "d331pap", chipID: 0x8020, boardID: 0x1A, marketingName: "iPhone XS Max"),
        ExpectedRow(productType: "iPhone11,8", hardwareModel: "n841ap", chipID: 0x8020, boardID: 0x0C, marketingName: "iPhone XR"),
        ExpectedRow(productType: "iPhone12,1", hardwareModel: "n104ap", chipID: 0x8030, boardID: 0x04, marketingName: "iPhone 11"),
        ExpectedRow(productType: "iPhone12,3", hardwareModel: "d421ap", chipID: 0x8030, boardID: 0x06, marketingName: "iPhone 11 Pro"),
        ExpectedRow(productType: "iPhone12,5", hardwareModel: "d431ap", chipID: 0x8030, boardID: 0x02, marketingName: "iPhone 11 Pro Max"),
        ExpectedRow(productType: "iPhone12,8", hardwareModel: "d79ap", chipID: 0x8030, boardID: 0x10, marketingName: "iPhone SE (2nd generation)")
    ]

    private static var failures: [String] = []

    static func main() {
        testExactCatalogRows()
        testBoundariesAndConflicts()
        testNormalAndRecoveryEvidence()
        testManifestCompatibility()
        testMockLocationUsesNormalIPhoneIdentity()

        if failures.isEmpty {
            print("SUPPORTED DEVICE CATALOG TEST PASS")
            exit(0)
        }
        failures.forEach { fputs("FAIL: \($0)\n", stderr) }
        exit(1)
    }

    private static func testExactCatalogRows() {
        let expectedModels = expectedRows.map(\.model)
        expect(SupportedDeviceCatalog.all == expectedModels, "catalog must contain the reviewed 14 rows in stable order")
        expect(SupportedDeviceCatalog.all.count == 14, "catalog must contain exactly 14 supported hardware rows")
        expect(Set(expectedRows.map(\.productType)).count == 14, "fixture ProductTypes must be unique")
        expect(Set(expectedRows.map(\.hardwareModel)).count == 14, "fixture HardwareModels must be unique")
        expect(SupportedDeviceCatalog.productTypes == Set(expectedRows.map(\.productType)), "catalog ProductType index must match all rows")
        expect(SupportedDeviceCatalog.hardwareModels == Set(expectedRows.map(\.hardwareModel)), "catalog HardwareModel index must match all rows")

        for row in expectedRows {
            let expected = row.model
            expect(SupportedDeviceCatalog.model(productType: row.productType) == expected, "ProductType lookup failed for \(row.productType)")
            expect(SupportedDeviceCatalog.model(hardwareModel: "  \(row.hardwareModel.uppercased())\n") == expected, "normalized HardwareModel lookup failed for \(row.hardwareModel)")
            expect(
                SupportedDeviceCatalog.model(
                    productType: row.productType,
                    hardwareModel: row.hardwareModel,
                    chipID: hex(row.chipID),
                    boardID: hex(row.boardID)
                ) == expected,
                "complete identity tuple failed for \(row.productType) / \(row.hardwareModel)"
            )
            expect(SupportedDeviceCatalog.marketingName(for: row.productType) == row.marketingName, "marketing name mismatch for \(row.productType)")
        }

        expect(SupportedDeviceCatalog.se2 == expectedRows.last?.model, "SE2 alias must point at the exact final catalog row")
    }

    private static func testBoundariesAndConflicts() {
        expect(SupportedDeviceCatalog.model(productType: "iPhone9,4") == nil, "iPhone 7 Plus must remain below the support boundary")
        expect(SupportedDeviceCatalog.model(productType: "iPhone13,1") == nil, "iPhone 12 mini must remain above the support boundary")
        expect(SupportedDeviceCatalog.model(productType: "iPhone12,9") == nil, "an unlisted in-range-looking ProductType must fail closed")
        expect(SupportedDeviceCatalog.model(hardwareModel: "d111ap") == nil, "an iPhone 7 hardware model must remain unsupported")
        expect(SupportedDeviceCatalog.model(hardwareModel: "d52gap") == nil, "an iPhone 12 mini hardware model must remain unsupported")

        let first = expectedRows[0]
        let second = expectedRows[1]
        expect(
            SupportedDeviceCatalog.model(productType: first.productType, hardwareModel: second.hardwareModel) == nil,
            "conflicting supported ProductType/HardwareModel evidence must fail closed"
        )
        expect(
            SupportedDeviceCatalog.model(productType: first.productType, hardwareModel: "d52gap") == nil,
            "supported ProductType plus unknown HardwareModel evidence must fail closed"
        )
        expect(
            SupportedDeviceCatalog.model(
                productType: first.productType,
                hardwareModel: first.hardwareModel,
                chipID: hex(first.chipID + 1),
                boardID: hex(first.boardID)
            ) == nil,
            "wrong CPID must reject an otherwise matching row"
        )
        expect(
            SupportedDeviceCatalog.model(
                productType: first.productType,
                hardwareModel: first.hardwareModel,
                chipID: hex(first.chipID),
                boardID: hex(first.boardID + 1)
            ) == nil,
            "wrong BDID must reject an otherwise matching row"
        )
    }

    private static func testNormalAndRecoveryEvidence() {
        for row in expectedRows {
            var normal = snapshot(for: row, mode: .normal)
            normal.recoveryIdentityQueryVerified = false
            expect(normal.supportedDeviceModel == row.model, "Normal identity did not resolve \(row.productType)")
            expect(normal.hasVerifiedSupportedDeviceIdentity, "verified Normal identity should authorize \(row.productType)")

            var productOnlyNormal = normal
            productOnlyNormal.hardwareModel = nil
            productOnlyNormal.chipID = nil
            productOnlyNormal.boardID = nil
            expect(productOnlyNormal.supportedDeviceModel == row.model, "Normal ProductType-only display identity should resolve \(row.productType)")
            expect(productOnlyNormal.hasVerifiedSupportedDeviceIdentity, "verified Normal ProductType should be sufficient for \(row.productType)")

            var hardwareOnlyNormal = normal
            hardwareOnlyNormal.productType = nil
            expect(hardwareOnlyNormal.supportedDeviceModel == row.model, "HardwareModel-only display identity should resolve \(row.hardwareModel)")
            expect(!hardwareOnlyNormal.hasVerifiedSupportedDeviceIdentity, "Normal write identity must require ProductType for \(row.hardwareModel)")

            var recovery = snapshot(for: row, mode: .recovery)
            recovery.recoveryIdentityQueryVerified = true
            expect(recovery.supportedDeviceModel == row.model, "Recovery tuple did not resolve \(row.productType)")
            expect(recovery.hasVerifiedSupportedDeviceIdentity, "complete verified Recovery tuple should authorize \(row.productType)")

            recovery.recoveryIdentityQueryVerified = false
            expect(!recovery.hasVerifiedSupportedDeviceIdentity, "unverified irecovery query must reject \(row.productType)")
            recovery.recoveryIdentityQueryVerified = true
            recovery.boardID = nil
            expect(!recovery.hasVerifiedSupportedDeviceIdentity, "Recovery tuple missing BDID must reject \(row.productType)")
        }

        var conflict = snapshot(for: expectedRows[0], mode: .normal)
        conflict.identityConflict = true
        expect(conflict.supportedDeviceModel == nil, "an observed identity conflict must suppress the resolved model")
        expect(!conflict.hasVerifiedSupportedDeviceIdentity, "an observed identity conflict must block write identity")
    }

    private static func testManifestCompatibility() {
        do {
            let allCustomerIdentities = expectedRows.map { manifestIdentity(for: $0, variant: "Customer Erase Install (IPSW)") }
            let allData = try manifestData(
                products: expectedRows.map(\.productType),
                identities: allCustomerIdentities
            )
            let allInfo = try IPSWValidator.inspectManifestData(allData)
            expect(allInfo.compatibleModels == Set(expectedRows.map(\.model)), "manifest parser must accept every exact Customer Erase target row")
            expect(allInfo.productVersion == "26.6.1" && allInfo.buildVersion == "23G83", "manifest software versions must be retained")

            let se2 = expectedRows[13]
            let exactSE2 = try IPSWValidator.inspectManifestData(
                manifestData(products: [se2.productType], identities: [manifestIdentity(for: se2, variant: "Customer Erase Install (IPSW)")])
            )
            expect(exactSE2.compatibleModels == [se2.model], "an exact SE2 manifest identity must match only SE2")

            let researchSE2 = try IPSWValidator.inspectManifestData(
                manifestData(products: [se2.productType], identities: [manifestIdentity(for: se2, variant: "Customer Erase Research Install (IPSW)")])
            )
            expect(researchSE2.compatibleModels.isEmpty, "a Research identity must be excluded even when it also says Customer Erase")

            var wrongProductIdentity = manifestIdentity(for: se2, variant: "Customer Erase Install (IPSW)")
            let wrongProduct = try IPSWValidator.inspectManifestData(
                manifestData(products: [expectedRows[10].productType], identities: [wrongProductIdentity])
            )
            expect(wrongProduct.compatibleModels.isEmpty, "matching board identity with the wrong SupportedProductTypes entry must be rejected")

            wrongProductIdentity["ApBoardID"] = hex(se2.boardID + 1)
            let wrongBoard = try IPSWValidator.inspectManifestData(
                manifestData(products: [se2.productType], identities: [wrongProductIdentity])
            )
            expect(wrongBoard.compatibleModels.isEmpty, "matching ProductType and DeviceClass with the wrong BDID must be rejected")

            var wrongClassIdentity = manifestIdentity(for: se2, variant: "Customer Erase Install (IPSW)")
            var wrongClassInfo = wrongClassIdentity["Info"] as? [String: Any] ?? [:]
            wrongClassInfo["DeviceClass"] = expectedRows[10].hardwareModel
            wrongClassIdentity["Info"] = wrongClassInfo
            let wrongClass = try IPSWValidator.inspectManifestData(
                manifestData(products: [se2.productType], identities: [wrongClassIdentity])
            )
            expect(wrongClass.compatibleModels.isEmpty, "matching ProductType with the wrong DeviceClass must be rejected")
        } catch {
            failures.append("manifest fixture failed: \(error.localizedDescription)")
        }
    }

    private static func testMockLocationUsesNormalIPhoneIdentity() {
        let row = expectedRows[10]
        var recovery = snapshot(for: row, mode: .recovery)
        recovery.recoveryIdentityQueryVerified = true
        expect(recovery.supportedDeviceModel == row.model, "iPhone 11 must resolve as a supported recovery target")
        expect(recovery.hasVerifiedSupportedDeviceIdentity, "iPhone 11 must pass complete Recovery identity verification")
        expect((try? MockLocationExactTarget(snapshot: recovery)) == nil, "Recovery mode must remain ineligible for Mock Location")

        let normal = snapshot(for: row, mode: .normal)
        do {
            let target = try MockLocationExactTarget(snapshot: normal)
            expect(target.productType == row.productType, "Normal-iOS Mock Location must pin the requested iPhone 11 ProductType")
            expect(target.matches(normal), "the generic Normal-iOS target must match its exact identity")
        } catch {
            failures.append("iPhone 11 Mock Location returned unexpected error: \(error.localizedDescription)")
        }
    }

    private static func snapshot(for row: ExpectedRow, mode: DeviceMode) -> DeviceSnapshot {
        DeviceSnapshot(
            mode: mode,
            deviceCount: 1,
            usbPID: mode == .normal ? 0x12A8 : 0x1281,
            locationID: 1_048_576,
            ecid: "0x123456789ABCDE",
            udid: "00008030-00123456789ABCDE",
            productType: row.productType,
            hardwareModel: row.hardwareModel,
            productVersion: mode == .normal ? "17.7" : nil,
            buildVersion: mode == .normal ? "21H16" : nil,
            activationState: mode == .normal ? "Activated" : nil,
            modeVerified: true,
            chipID: hex(row.chipID),
            boardID: hex(row.boardID),
            recoveryIdentityQueryVerified: mode == .recovery || mode == .dfu
        )
    }

    private static func manifestIdentity(for row: ExpectedRow, variant: String) -> [String: Any] {
        [
            "ApChipID": hex(row.chipID),
            "ApBoardID": hex(row.boardID),
            "Info": [
                "DeviceClass": row.hardwareModel,
                "Variant": variant
            ]
        ]
    }

    private static func manifestData(
        products: [String],
        identities: [[String: Any]]
    ) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: [
                "ProductVersion": "26.6.1",
                "ProductBuildVersion": "23G83",
                "SupportedProductTypes": products,
                "BuildIdentities": identities
            ],
            format: .binary,
            options: 0
        )
    }

    private static func hex(_ value: UInt64) -> String {
        String(format: "0x%llX", value)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { failures.append(message) }
    }
}
