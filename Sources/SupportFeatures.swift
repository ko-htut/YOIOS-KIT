import Darwin
import Foundation

enum DeviceTimelineCategory: String, Codable {
    case app = "App"
    case detection = "Detection"
    case usb = "USB"
    case recovery = "Recovery"
    case operation = "Operation"
    case support = "Support"
}

enum DeviceTimelineSeverity: String, Codable {
    case info
    case success
    case warning
    case error
}

struct DeviceTimelineEvent: Identifiable, Equatable, Codable {
    let id: UUID
    let observedAt: Date
    let category: DeviceTimelineCategory
    let severity: DeviceTimelineSeverity
    let title: String
    let detail: String
    let mode: DeviceMode?
    let usbPID: Int?

    init(
        id: UUID = UUID(),
        observedAt: Date = Date(),
        category: DeviceTimelineCategory,
        severity: DeviceTimelineSeverity = .info,
        title: String,
        detail: String,
        mode: DeviceMode? = nil,
        usbPID: Int? = nil
    ) {
        self.id = id
        self.observedAt = observedAt
        self.category = category
        self.severity = severity
        self.title = title
        self.detail = detail
        self.mode = mode
        self.usbPID = usbPID
    }
}

enum DeviceTimelineReportBuilder {
    static func redactedText(
        events: [DeviceTimelineEvent],
        snapshot: DeviceCenterSnapshot
    ) -> String {
        let iso = ISO8601DateFormatter()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var lines = [
            "YIOS-KIT Device Center — redacted USB and recovery timeline",
            "Exported: \(iso.string(from: Date()))",
            "",
            "Scope: this app session. Events may span a disconnect or target change and are not attributed to one current-device token.",
            "Identifiers and local paths are masked. This timeline contains app-observed connection and operation evidence, not iPhone syslog or crash-report contents."
        ]

        for event in events.sorted(by: { $0.observedAt < $1.observedAt }) {
            let raw = event.detail.isEmpty ? event.title : "\(event.title) — \(event.detail)"
            let knownSafe = DeviceCenterPrivacy.redactOperationalText(
                raw,
                ecids: [snapshot.targetECID].compactMap { $0 },
                udids: [snapshot.targetUDID].compactMap { $0 },
                facts: snapshot.facts,
                localPaths: [home]
            )
            let safe = redactIdentifierPatterns(knownSafe)
            var evidence: [String] = [event.category.rawValue, event.severity.rawValue.uppercased()]
            if let mode = event.mode { evidence.append(mode.title) }
            if let pid = event.usbPID { evidence.append(String(format: "PID 0x%04X", pid)) }
            lines.append("\(iso.string(from: event.observedAt)) | \(evidence.joined(separator: " | ")) | \(safe)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func redactIdentifierPatterns(_ value: String) -> String {
        let patterns = [
            #"(?i)0x[0-9a-f]{10,16}"#,
            #"(?i)\b[0-9a-f]{8}-[0-9a-f]{16}\b"#,
            #"(?i)\b[0-9a-f]{13,16}\b"#,
            #"\b[0-9]{13,20}\b"#
        ]
        var output = value
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            output = regex.stringByReplacingMatches(
                in: output,
                range: NSRange(output.startIndex..., in: output),
                withTemplate: "[identifier masked]"
            )
        }
        return output
    }
}

struct CrashReportCopySummary: Equatable {
    let copiedAt: Date
    let directoryURL: URL
    let fileCount: Int
    let panicNamedFileCount: Int
    let enumerationWasTruncated: Bool
    let privacySecured: Bool
    let securityIssueCount: Int
    var targetVerifiedAfterCopy: Bool
}

enum DeviceSupportCommandBuilder {
    static func copyCrashReports(udid: String, destination: URL) -> [String] {
        ["--udid", udid, "--keep", destination.path]
    }
}

enum CrashReportOutputValidator {
    static func reportedUnsafeMutation(_ output: String) -> Bool {
        output.components(separatedBy: .newlines).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return trimmed.hasPrefix("move:") || trimmed.hasPrefix("remove:")
        }
    }

    enum Issue: Equatable {
        case nonzeroExit(Int32)
        case unsafeMutation
        case stderrOutput
        case missingTerminalDone
        case partialFailureMarker
    }

    static func issue(exitCode: Int32, stdout: String, stderr: String) -> Issue? {
        let combined = stdout + "\n" + stderr
        if reportedUnsafeMutation(combined) { return .unsafeMutation }
        guard exitCode == 0 else { return .nonzeroExit(exitCode) }
        if !stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .stderrOutput }

        let lines = stdout.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.last?.caseInsensitiveCompare("Done.") == .orderedSame else {
            return .missingTerminalDone
        }
        let lower = stdout.lowercased()
        let failureMarkers = [
            "failed to ",
            "skipping",
            "unable to ",
            "file size mismatch",
            "could not ",
            "error:"
        ]
        if failureMarkers.contains(where: { lower.contains($0) }) {
            return .partialFailureMarker
        }
        return nil
    }

    static func completedSafely(exitCode: Int32, stdout: String, stderr: String) -> Bool {
        issue(exitCode: exitCode, stdout: stdout, stderr: stderr) == nil
    }
}

enum CrashReportReviewPolicy {
    static func requiresReview(
        timedOut: Bool,
        validationIssue: CrashReportOutputValidator.Issue?,
        privacyVerified: Bool,
        targetVerified: Bool
    ) -> Bool {
        timedOut || validationIssue == .unsafeMutation || !privacyVerified || !targetVerified
    }
}

enum CrashReportFailureReasonBuilder {
    static func commandReasons(
        timedOut: Bool,
        validationIssue: CrashReportOutputValidator.Issue?
    ) -> [String] {
        var reasons: [String] = []
        if timedOut {
            reasons.append("The copy timed out; partial local files may exist.")
        }
        guard let validationIssue else { return reasons }
        switch validationIssue {
        case .nonzeroExit(let code):
            if !timedOut { reasons.append("idevicecrashreport exited with code \(code).") }
        case .unsafeMutation:
            reasons.append("The tool reported Move/Remove despite the mandatory --keep contract.")
        case .stderrOutput:
            reasons.append("The tool emitted diagnostic output on stderr, so completion was not trusted.")
        case .missingTerminalDone:
            reasons.append("The tool did not finish with the required Done. marker.")
        case .partialFailureMarker:
            reasons.append("The tool reported a skipped or partially failed file.")
        }
        return reasons
    }
}

enum CrashReportInspector {
    static func createPrivateDestination(in parent: URL, at date: Date = Date()) throws -> URL {
        let parent = parent.standardizedFileURL.resolvingSymlinksInPath()
        let values = try parent.resourceValues(forKeys: [.isDirectoryKey, .volumeIsLocalKey])
        guard values.isDirectory == true,
              values.volumeIsLocal == true,
              FileManager.default.isWritableFile(atPath: parent.path) else {
            throw NSError(
                domain: "local.minthanhtut.SE2RecoveryAssistant.CrashReports",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The selected parent must be a writable folder on a local Mac volume."]
            )
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let baseName = "YIOS-Crash-Reports-\(formatter.string(from: date))"
        var destination = parent.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = parent.appendingPathComponent("\(baseName)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            guard securePermissions(at: destination, mode: 0o700) else {
                throw NSError(
                    domain: "local.minthanhtut.SE2RecoveryAssistant.CrashReports",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "The selected volume could not enforce private ownership, 0700 permissions, and an ACL-free folder."]
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return destination
    }

    static func summarizeAndSecure(directory: URL, copiedAt: Date = Date()) -> CrashReportCopySummary {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey
        ]
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        var securityIssues = 0
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in
                securityIssues += 1
                return true
            }
        )
        var fileCount = 0
        var panicNamed = 0
        var inspectedEntries = 0
        var truncated = false
        while let url = enumerator?.nextObject() as? URL {
            inspectedEntries += 1
            if inspectedEntries > 20_000 {
                truncated = true
                break
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                securityIssues += 1
                continue
            }
            if values.isSymbolicLink == true {
                securityIssues += 1
                enumerator?.skipDescendants()
                continue
            }
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(root.path + "/") else {
                securityIssues += 1
                enumerator?.skipDescendants()
                continue
            }
            if values.isDirectory == true {
                if !securePermissions(at: url, mode: 0o700) { securityIssues += 1 }
            } else if values.isRegularFile == true {
                fileCount += 1
                if url.lastPathComponent.localizedCaseInsensitiveContains("panic") { panicNamed += 1 }
                if !securePermissions(at: url, mode: 0o600) { securityIssues += 1 }
            } else {
                securityIssues += 1
            }
        }
        if !securePermissions(at: directory, mode: 0o700) { securityIssues += 1 }
        return CrashReportCopySummary(
            copiedAt: copiedAt,
            directoryURL: directory,
            fileCount: fileCount,
            panicNamedFileCount: panicNamed,
            enumerationWasTruncated: truncated,
            privacySecured: securityIssues == 0 && !truncated,
            securityIssueCount: securityIssues,
            targetVerifiedAfterCopy: false
        )
    }

    private static func permissions(at url: URL) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attrs[.posixPermissions] as? NSNumber else { return nil }
        return number.intValue & 0o777
    }

    private static func securePermissions(at url: URL, mode: Int) -> Bool {
        guard stripExtendedACL(at: url) else { return false }
        do {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        } catch {
            return false
        }
        guard permissions(at: url) == mode,
              ownerIsCurrentUser(at: url),
              hasNoExtendedACL(at: url) else { return false }
        return true
    }

    private static func stripExtendedACL(at url: URL) -> Bool {
        guard let emptyACL = acl_init(0) else { return false }
        defer { acl_free(UnsafeMutableRawPointer(emptyACL)) }
        return acl_set_file(url.path, ACL_TYPE_EXTENDED, emptyACL) == 0
    }

    private static func hasNoExtendedACL(at url: URL) -> Bool {
        errno = 0
        if let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) {
            acl_free(UnsafeMutableRawPointer(acl))
            return false
        }
        return errno == ENOENT
    }

    private static func ownerIsCurrentUser(at url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let owner = attrs[.ownerAccountID] as? NSNumber else { return false }
        return owner.uint32Value == geteuid()
    }
}
