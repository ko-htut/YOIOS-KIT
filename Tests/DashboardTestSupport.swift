import Foundation

enum DashboardTestSupport {
    static let dependencyDoctorSnapshot: DependencyDoctorSnapshot = {
        let helperRoot = URL(fileURLWithPath: "/Applications/YIOS-KIT.app/Contents/Helpers/YIOSTools", isDirectory: true)
        let configuratorRoot = URL(fileURLWithPath: "/Applications/Apple Configurator.app/Contents/MacOS", isDirectory: true)

        func resolved(_ kind: ToolKind) -> ResolvedTool? {
            switch kind {
            case .homebrew:
                return nil
            case .cfgutil:
                return ResolvedTool(
                    kind: kind,
                    executableURL: configuratorRoot.appendingPathComponent(kind.executableName),
                    source: .appleConfigurator,
                    advertisedVersion: "2.20"
                )
            case .irecovery:
                return ResolvedTool(
                    kind: kind,
                    executableURL: helperRoot.appendingPathComponent(kind.executableName),
                    source: .bundled,
                    advertisedVersion: "1.3.1"
                )
            case .ideviceID, .ideviceInfo, .idevicePair, .ideviceEnterRecovery,
                 .ideviceDiagnostics, .ideviceCrashReport:
                return ResolvedTool(
                    kind: kind,
                    executableURL: helperRoot.appendingPathComponent(kind.executableName),
                    source: .bundled,
                    advertisedVersion: "1.4.0"
                )
            }
        }

        let resolvedTools = Dictionary(uniqueKeysWithValues: ToolKind.allCases.compactMap { kind in
            resolved(kind).map { (kind, $0) }
        })
        let toolStatuses = ToolKind.allCases.map { kind in
            let tool = resolvedTools[kind]
            return DependencyToolStatus(
                kind: kind,
                isAvailable: tool != nil,
                source: tool?.source,
                version: tool?.advertisedVersion,
                displayLocation: tool?.displayLocation
            )
        }
        let capabilities = ToolCapability.allCases.map { capability in
            let tools = Dictionary(uniqueKeysWithValues: capability.requiredTools.compactMap { kind in
                resolvedTools[kind].map { (kind, $0) }
            })
            return ToolCapabilityResolution(
                capability: capability,
                tools: tools,
                unavailableTools: capability.requiredTools.filter { tools[$0] == nil }
            )
        }
        let components = [
            DependencyComponentStatus(
                component: .homebrew,
                requirement: .optionalFallback,
                health: .notRequired,
                version: nil,
                sourceSummary: "Not needed",
                availableTools: [],
                missingTools: [],
                detail: "Built-in mobile-device tools are available; Homebrew is not required."
            ),
            DependencyComponentStatus(
                component: .appleConfigurator,
                requirement: .advancedAppleOperations,
                health: .ready,
                version: "2.20",
                sourceSummary: "Apple Configurator",
                availableTools: [.cfgutil],
                missingTools: [],
                detail: "Official Apple Revive, Restore, and Factory Reset tooling is available."
            ),
            DependencyComponentStatus(
                component: .libimobiledevice,
                requirement: .coreInspection,
                health: .ready,
                version: "1.4.0",
                sourceSummary: "Built in",
                availableTools: ToolKind.libimobiledeviceTools,
                missingTools: [],
                detail: "Built-in Normal-iOS identity and supported utilities are ready."
            ),
            DependencyComponentStatus(
                component: .libirecovery,
                requirement: .coreInspection,
                health: .ready,
                version: "1.3.1",
                sourceSummary: "Built in",
                availableTools: [.irecovery],
                missingTools: [],
                detail: "Built-in Recovery and DFU protocol verification is ready."
            )
        ]
        return DependencyDoctorSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            components: components,
            tools: toolStatuses,
            capabilities: capabilities,
            manifestState: .unavailable
        )
    }()
}
