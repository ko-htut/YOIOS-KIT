import Foundation

@main
struct SupportFeaturesTestMain {
    private static var failures: [String] = []

    static func main() {
        testCrashCommandIsKeepOnlyAndTargeted()
        testPrivateDestinationAndSummary()
        testTimelineExportRedaction()

        if failures.isEmpty {
            print("SUPPORT FEATURES TEST PASS")
            exit(0)
        }
        failures.forEach { fputs("FAIL: \($0)\n", stderr) }
        exit(1)
    }

    private static func testCrashCommandIsKeepOnlyAndTargeted() {
        let destination = URL(fileURLWithPath: "/private/tmp/private-crash-fixture", isDirectory: true)
        let argv = DeviceSupportCommandBuilder.copyCrashReports(
            udid: "00008030-TEST-TARGET",
            destination: destination
        )
        expect(argv == ["--udid", "00008030-TEST-TARGET", "--keep", destination.path], "crash argv must use exact UDID + mandatory --keep + destination")
        expect(!argv.contains("--network") && !argv.contains("-n"), "crash argv must never enable network discovery")
        expect(!argv.contains("--remove-all"), "crash argv must never expose report deletion")
        expect(!argv.contains("--extract") && !argv.contains("-e"), "v1.4 must not create extra raw extracted copies")
        expect(CrashReportOutputValidator.completedSafely(exitCode: 0, stdout: "Copy: fixture.ips\nDone.", stderr: ""), "copy-only output may complete")
        expect(CrashReportOutputValidator.completedSafely(exitCode: 0, stdout: "Done.", stderr: ""), "zero reports with terminal Done is a clean completion")
        expect(!CrashReportOutputValidator.completedSafely(exitCode: 0, stdout: "Move: fixture.ips\nDone.", stderr: ""), "Move output must never be presented as safe success")
        expect(CrashReportOutputValidator.reportedUnsafeMutation("REMOVE: fixture.ips"), "Remove output must trigger manual review case-insensitively")
        expect(!CrashReportOutputValidator.completedSafely(exitCode: 0, stdout: "Done.", stderr: "Move: fixture.ips"), "stderr mutation must never be presented as success")
        expect(CrashReportOutputValidator.issue(exitCode: 1, stdout: "Move: fixture.ips", stderr: "") == .unsafeMutation, "unsafe mutation must outrank a nonzero exit and trigger review")
        expect(CrashReportOutputValidator.issue(exitCode: -2, stdout: "", stderr: "Remove: fixture.ips") == .unsafeMutation, "unsafe mutation must outrank a timeout-style exit and trigger review")
        expect(CrashReportReviewPolicy.requiresReview(timedOut: true, validationIssue: .nonzeroExit(-2), privacyVerified: true, targetVerified: true), "a timeout must always arm the manual-review lock")
        expect(CrashReportReviewPolicy.requiresReview(timedOut: false, validationIssue: .unsafeMutation, privacyVerified: true, targetVerified: true), "an unsafe movement report must always arm the manual-review lock")
        expect(!CrashReportReviewPolicy.requiresReview(timedOut: false, validationIssue: .nonzeroExit(1), privacyVerified: true, targetVerified: true), "an ordinary clean failure may be retried explicitly after fixing the cause")
        let timeoutMutationReasons = CrashReportFailureReasonBuilder.commandReasons(
            timedOut: true,
            validationIssue: .unsafeMutation
        )
        expect(timeoutMutationReasons.contains(where: { $0.localizedCaseInsensitiveContains("timed out") }), "timeout disclosure must be retained")
        expect(timeoutMutationReasons.contains(where: { $0.contains("Move/Remove") && $0.contains("--keep") }), "a timeout that also reports mutation must disclose the keep-contract contradiction")
        expect(!CrashReportOutputValidator.completedSafely(exitCode: 0, stdout: "Failed to read information. Skipping\nDone.", stderr: ""), "exit-zero partial failure must not be presented as success")
        expect(!CrashReportOutputValidator.completedSafely(exitCode: 0, stdout: "Copy: fixture.ips", stderr: ""), "missing terminal Done must not be presented as success")
        expect(!CrashReportOutputValidator.completedSafely(exitCode: 0, stdout: "Done.", stderr: "File size mismatch"), "nonempty stderr must prevent a privacy-success claim")
        expect(!CrashReportOutputValidator.completedSafely(exitCode: 1, stdout: "Done.", stderr: ""), "nonzero exit must not be presented as success")
    }

    private static func testPrivateDestinationAndSummary() {
        let fileManager = FileManager.default
        let parent = fileManager.temporaryDirectory
            .appendingPathComponent("YIOS-KIT-Support-Test-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: parent,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            defer { try? fileManager.removeItem(at: parent) }

            let first = try CrashReportInspector.createPrivateDestination(
                in: parent,
                at: Date(timeIntervalSince1970: 1_700_000_000)
            )
            let second = try CrashReportInspector.createPrivateDestination(
                in: parent,
                at: Date(timeIntervalSince1970: 1_700_000_000)
            )
            expect(first != second, "support copy must never reuse or overwrite an existing destination")

            let aclParent = parent.appendingPathComponent("acl-parent", isDirectory: true)
            try fileManager.createDirectory(at: aclParent, withIntermediateDirectories: false)
            let chmod = Process()
            chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmod.arguments = [
                "+a",
                "everyone allow list,search,readattr,readextattr,readsecurity,file_inherit,directory_inherit",
                aclParent.path
            ]
            try chmod.run()
            chmod.waitUntilExit()
            expect(chmod.terminationStatus == 0, "ACL inheritance fixture must be created")
            let aclSafe = try CrashReportInspector.createPrivateDestination(
                in: aclParent,
                at: Date(timeIntervalSince1970: 1_700_000_000)
            )
            let aclListing = ProcessRunner.run("/bin/ls", ["-led", aclSafe.path], timeout: 5)
            expect(aclListing.exitCode == 0 && !aclListing.stdout.contains(" inherited "), "new crash folder must strip inherited ACL entries before device contact")

            let ordinary = first.appendingPathComponent("Example.ips")
            let panicNamed = first.appendingPathComponent("panic-full-fixture.ips")
            let hidden = first.appendingPathComponent(".hidden-fixture.ips")
            try Data("fixture".utf8).write(to: ordinary, options: .atomic)
            try Data("fixture".utf8).write(to: panicNamed, options: .atomic)
            try Data("fixture".utf8).write(to: hidden, options: .atomic)
            let summary = CrashReportInspector.summarizeAndSecure(directory: first)
            expect(summary.fileCount == 3, "summary must include hidden copied regular files")
            expect(summary.panicNamedFileCount == 1, "panic-named count must remain a filename observation only")
            expect(summary.privacySecured, "happy-path local permissions must be verified after enumeration")
            expect(summary.securityIssueCount == 0 && !summary.enumerationWasTruncated, "happy-path security audit must be complete")
            expect(!summary.targetVerifiedAfterCopy, "filesystem inspection alone must never claim post-copy target verification")

            let directoryMode = ((try fileManager.attributesOfItem(atPath: first.path)[.posixPermissions]) as? NSNumber)?.intValue
            let fileMode = ((try fileManager.attributesOfItem(atPath: ordinary.path)[.posixPermissions]) as? NSNumber)?.intValue
            expect(directoryMode == 0o700, "crash destination must be permission 0700")
            expect(fileMode == 0o600, "copied crash files must be permission 0600")

            let outside = parent.appendingPathComponent("outside-fixture")
            try Data("outside".utf8).write(to: outside, options: .atomic)
            let link = second.appendingPathComponent("unsafe-link")
            try fileManager.createSymbolicLink(at: link, withDestinationURL: outside)
            let unsafeSummary = CrashReportInspector.summarizeAndSecure(directory: second)
            expect(!unsafeSummary.privacySecured && unsafeSummary.securityIssueCount > 0, "a symbolic link must fail the privacy audit")
        } catch {
            failures.append("private destination fixture failed: \(error.localizedDescription)")
        }
    }

    private static func testTimelineExportRedaction() {
        let ecid = "0x123456789ABCDE"
        let udid = "00008030-00123456789ABCDE"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let device = DeviceSnapshot(
            mode: .recovery,
            deviceCount: 1,
            usbPID: 0x1281,
            locationID: 1_048_576,
            ecid: ecid,
            udid: udid,
            productType: "iPhone10,1",
            hardwareModel: "d20ap",
            modeVerified: true,
            chipID: "0x8015",
            boardID: "0x02",
            recoveryIdentityQueryVerified: true
        )
        let snapshot = DeviceCenterCollector.baseline(
            for: device,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let events = [
            DeviceTimelineEvent(
                observedAt: Date(timeIntervalSince1970: 1_700_000_001),
                category: .usb,
                severity: .warning,
                title: "Target \(ecid)",
                detail: "UDID \(udid) path \(home)/private.log",
                mode: .recovery,
                usbPID: 0x1281
            ),
            DeviceTimelineEvent(
                observedAt: Date(timeIntervalSince1970: 1_700_000_002),
                category: .detection,
                title: "Different target 0xABCDEF12345678",
                detail: "Swapped UDID 00008030-00ABCDEF12345678 bare ABCDEF12345678 decimal 48358647703819896",
                mode: .normal,
                usbPID: 0x12A8
            )
        ]
        let report = DeviceTimelineReportBuilder.redactedText(events: events, snapshot: snapshot)
        expect(!report.localizedCaseInsensitiveContains(ecid), "timeline export must mask ECID aliases")
        expect(!report.localizedCaseInsensitiveContains(udid), "timeline export must mask UDID")
        expect(!report.contains(home), "timeline export must mask the local home path")
        expect(!report.contains("0xABCDEF12345678") && !report.contains("00008030-00ABCDEF12345678"), "timeline export must mask an older target after a swap")
        expect(!report.contains("ABCDEF12345678") && !report.contains("48358647703819896"), "timeline export must mask bare-hex and decimal identifier aliases")
        expect(!report.contains("Target token:"), "multi-target session export must not be mislabeled with only the current target token")
        expect(report.contains("Recovery Mode") && report.contains("0x1281"), "timeline export must retain non-sensitive mode/PID evidence")
        expect(!report.contains("Finder success"), "timeline must not invent Finder backup evidence")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { failures.append(message) }
    }
}
