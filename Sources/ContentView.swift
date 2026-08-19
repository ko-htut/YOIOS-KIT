import SwiftUI

enum AppWorkspaceSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case recovery = "Recovery"
    case evidence = "Evidence"
    case activity = "Activity"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .overview: return "rectangle.grid.2x2"
        case .recovery: return "cross.case"
        case .evidence: return "checkmark.shield"
        case .activity: return "waveform.path.ecg"
        }
    }
}

enum AppSidebarDestination: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case devices = "Devices"
    case reports = "Reports"
    case history = "History"
    case recovery = "Recovery"
    case dfuRestore = "DFU / Restore"
    case moreTools = "More Tools"
    case guides = "Guides"
    case logs = "Logs"
    case settings = "Settings"

    var id: String { rawValue }

    var workspace: AppWorkspaceSection {
        switch self {
        case .dashboard, .devices: return .overview
        case .recovery, .dfuRestore, .guides: return .recovery
        case .settings: return .overview
        case .reports: return .evidence
        case .history, .moreTools, .logs: return .activity
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: return "house.fill"
        case .devices: return "iphone"
        case .reports: return "doc.text"
        case .history: return "clock.arrow.circlepath"
        case .recovery: return "arrow.clockwise.circle"
        case .dfuRestore: return "cross.case"
        case .moreTools: return "square.grid.2x2"
        case .guides: return "book.closed"
        case .logs: return "list.clipboard"
        case .settings: return "gearshape"
        }
    }

    var group: SidebarGroup {
        switch self {
        case .dashboard, .devices, .reports, .history: return .main
        case .recovery, .dfuRestore, .moreTools: return .tools
        case .guides, .logs, .settings: return .resources
        }
    }

    enum SidebarGroup: String, CaseIterable {
        case main = "MAIN"
        case tools = "TOOLS"
        case resources = "RESOURCES"
    }

    static func canonical(for section: AppWorkspaceSection) -> AppSidebarDestination {
        switch section {
        case .overview: return .dashboard
        case .recovery: return .recovery
        case .evidence: return .reports
        case .activity: return .history
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: RecoveryModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var isDFUExpanded = false
    @State private var isLogExpanded = false
    @State private var isDependencyDoctorExpanded = false
    @State private var selectedSection: AppWorkspaceSection
    @State private var selectedDestination: AppSidebarDestination
    @State private var appearancePreference = "system"
    private let rendersFullContent: Bool

    init(
        model: RecoveryModel,
        initiallyExpandDFUGuide: Bool = false,
        initiallyExpandLog: Bool = false,
        rendersFullContent: Bool = false,
        initialSection: AppWorkspaceSection? = nil,
        initialDestination: AppSidebarDestination? = nil
    ) {
        self.model = model
        _isDFUExpanded = State(initialValue: initiallyExpandDFUGuide)
        _isLogExpanded = State(initialValue: initiallyExpandLog)
        let section = initialDestination?.workspace ?? initialSection ?? Self.defaultSection(for: model)
        _selectedSection = State(initialValue: section)
        let destination: AppSidebarDestination
        if model.crashCopyReviewRequired {
            destination = .logs
        } else if model.postResetReviewRequired {
            destination = .recovery
        } else {
            destination = initialDestination ?? AppSidebarDestination.canonical(for: section)
        }
        _selectedDestination = State(initialValue: destination)
        self.rendersFullContent = rendersFullContent
    }

    private static func defaultSection(for model: RecoveryModel) -> AppWorkspaceSection {
        if model.crashCopyReviewRequired { return .activity }
        if model.postResetReviewRequired { return .recovery }
        switch model.snapshot.mode {
        case .recovery, .dfu, .restoreOS, .usbUnavailable, .unknown, .multiple:
            return .recovery
        case .normal, .notDetected:
            return .overview
        }
    }

    private var modeColor: Color {
        switch model.snapshot.mode {
        case .normal: return .green
        case .recovery: return .blue
        case .dfu: return .purple
        case .restoreOS, .usbUnavailable: return .orange
        case .notDetected, .unknown: return .secondary
        case .multiple: return .red
        }
    }

    private var modeSymbol: String {
        switch model.snapshot.mode {
        case .normal: return "checkmark.circle.fill"
        case .recovery: return "arrow.clockwise.circle.fill"
        case .dfu: return "iphone"
        case .restoreOS: return "exclamationmark.triangle.fill"
        case .usbUnavailable: return "cable.connector"
        case .notDetected: return "iphone.slash"
        case .unknown: return "questionmark.circle.fill"
        case .multiple: return "exclamationmark.triangle.fill"
        }
    }

    private var showsButtonGuide: Bool {
        model.snapshot.mode == .restoreOS ||
        ((model.snapshot.mode == .usbUnavailable || model.snapshot.mode == .unknown) &&
         model.snapshot.deviceCount == 1 && model.snapshot.ecid != nil) ||
        model.isMonitoring
    }

    private var statusTintOpacity: Double {
        colorScheme == .dark ? 0.16 : 0.08
    }

    private var statusAccentColor: Color {
        if model.crashCopyReviewRequired { return .red }
        if model.postResetReviewRequired { return .orange }
        return modeColor
    }

    private var statusIcon: String {
        if model.crashCopyReviewRequired { return "exclamationmark.octagon.fill" }
        if model.postResetReviewRequired { return "eye.circle.fill" }
        return modeSymbol
    }

    private var statusEyebrow: String? {
        if model.crashCopyReviewRequired { return "Manual crash-copy review required" }
        if model.postResetReviewRequired { return "Manual confirmation required" }
        return nil
    }

    private var statusBadgeTitle: String {
        if model.crashCopyReviewRequired { return "Crash review locked" }
        return compactModeTitle
    }

    private var compactModeTitle: String {
        switch model.snapshot.mode {
        case .restoreOS: return "RestoreOS intermediate"
        case .multiple: return "Multiple devices"
        default: return model.snapshot.mode.title
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            HStack(spacing: 0) {
                sidebar
                    .frame(width: 226)

                Divider()

                VStack(spacing: 0) {
                    if (selectedDestination != .dashboard && selectedDestination != .devices) ||
                        model.postResetReviewRequired || model.crashCopyReviewRequired {
                        statusBanner
                            .padding(.horizontal, 18)
                            .padding(.vertical, 11)
                        Divider()
                    }

                    workspaceContent
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            footer
        }
        .frame(minWidth: 1_040, idealWidth: 1_420, minHeight: 700, idealHeight: 880)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(preferredColorScheme)
        .onChange(of: model.postResetReviewRequired) { required in
            if required { select(.recovery) }
        }
        .onChange(of: model.crashCopyReviewRequired) { required in
            if required { select(.logs) }
        }
        .onChange(of: model.snapshot.mode) { mode in
            if [.recovery, .dfu, .restoreOS, .usbUnavailable, .unknown, .multiple].contains(mode),
               selectedSection == .overview {
                select(.recovery)
            }
        }
        .onChange(of: selectedSection) { section in
            if selectedDestination.workspace != section {
                selectedDestination = AppSidebarDestination.canonical(for: section)
            }
        }
    }

    @ViewBuilder
    private var workspaceContent: some View {
        switch selectedDestination {
        case .dashboard, .devices:
            DashboardOverviewView(model: model) {
                select(.moreTools)
            }
        case .recovery, .dfuRestore, .guides:
            GeometryReader { geometry in
                if geometry.size.width >= 820 {
                    if rendersFullContent {
                        twoColumnFullContent(width: geometry.size.width)
                    } else {
                        twoColumnBody(width: geometry.size.width)
                    }
                } else {
                    stackedBody
                }
            }
        case .settings:
            DashboardSettingsView(model: model) {
                select(.dashboard)
            }
        case .reports:
            DeviceEvidenceView(model: model)
        case .history, .moreTools, .logs:
            DeviceActivityView(model: model)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "iphone.gen2.radiowaves.left.and.right")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("YIOS-KIT")
                    .font(.title2.weight(.semibold))
                Text("iOS Recovery & Diagnostic Suite")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Picker("Workspace", selection: $selectedSection) {
                ForEach(AppWorkspaceSection.allCases) { section in
                    Label(section.rawValue, systemImage: section.systemImage)
                        .tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 390)
            .accessibilityIdentifier("workspacePicker")

            Spacer(minLength: 12)

            if model.isScanning || model.isLoadingDeviceCenter {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(model.isLoadingDeviceCenter ? "Loading device details" : "Scanning for iPhone")
            }

            Button {
                cycleAppearance()
            } label: {
                Image(systemName: appearanceSymbol)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help("Appearance: \(appearancePreference.capitalized)")
            .accessibilityLabel(appearanceAccessibilityLabel)
            .accessibilityIdentifier("appearanceButton")

            Button {
                select(.settings)
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help("Open settings and system readiness")
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("settingsButton")

            Button {
                model.scan()
            } label: {
                Label("New Scan", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.operationRunning || model.destructiveWorkflowActive || model.postResetReviewRequired || model.isScanning || model.isMonitoring || model.isValidatingFirmware || model.isLoadingDeviceCenter)
            .accessibilityIdentifier("scanButton")
        }
        .padding(.leading, 88)
        .padding(.trailing, 20)
        .padding(.vertical, 11)
        .frame(minHeight: 64)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("appHeader")
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(AppSidebarDestination.SidebarGroup.allCases, id: \.self) { group in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(group.rawValue)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)

                            ForEach(AppSidebarDestination.allCases.filter { $0.group == group }) { destination in
                                sidebarButton(destination)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 16)
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                sidebarReadinessCard

                HStack(spacing: 9) {
                    ZStack {
                        Circle()
                            .fill(Color.blue.opacity(colorScheme == .dark ? 0.24 : 0.12))
                        Image(systemName: "person.crop.circle")
                            .foregroundStyle(.blue)
                    }
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Personal workspace")
                            .font(.caption.weight(.semibold))
                        Text("Local on this Mac")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.42), lineWidth: 1)
                )
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("localWorkspaceCard")
            }
            .padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("appSidebar")
    }

    private func sidebarButton(_ destination: AppSidebarDestination) -> some View {
        let isSelected = selectedDestination == destination
        return Button {
            select(destination)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: destination.systemImage)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Color.blue : Color.secondary)
                Text(destination.rawValue)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.blue.opacity(colorScheme == .dark ? 0.20 : 0.09) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(destination.rawValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("sidebar\(destination.rawValue.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "/", with: ""))Button")
    }

    private var sidebarReadinessCard: some View {
        let mobile = model.dependencyDoctorSnapshot.component(.libimobiledevice)
        let recovery = model.dependencyDoctorSnapshot.component(.libirecovery)
        let coreReady = mobile?.health == .ready && recovery?.health == .ready
        return VStack(alignment: .leading, spacing: 7) {
            Label(
                coreReady ? "Inspection tools ready" : "Tool attention needed",
                systemImage: coreReady ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(coreReady ? Color.green : Color.orange)

            Text(coreReady
                 ? "Built-in device and recovery inspection tools are available."
                 : "Open Settings to review missing or incompatible dependencies.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("View readiness") { select(.settings) }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .accessibilityIdentifier("sidebarReadinessButton")
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke((coreReady ? Color.green : Color.orange).opacity(0.22), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebarReadinessCard")
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Text("YIOS-KIT \(appVersionLabel)")
                .font(.caption.weight(.semibold))
            Text("•")
                .foregroundStyle(.tertiary)
            Circle()
                .fill(footerStatusColor)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(footerStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Label("Actions require an explicit choice", systemImage: "shield.lefthalf.filled")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .frame(height: 42)
        .background(.bar)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("appFooter")
    }

    private var preferredColorScheme: ColorScheme? {
        switch appearancePreference {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    private var appearanceSymbol: String {
        switch appearancePreference {
        case "light": return "sun.max"
        case "dark": return "moon.stars"
        default: return "circle.lefthalf.filled"
        }
    }

    private var appearanceAccessibilityLabel: String {
        switch appearancePreference {
        case "light": return "Appearance is Light. Switch to Dark appearance"
        case "dark": return "Appearance is Dark. Switch to System appearance"
        default: return "Appearance follows System. Switch to Light appearance"
        }
    }

    private var appVersionLabel: String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !version.isEmpty else {
            return "Development"
        }
        return "v\(version)"
    }

    private var footerStatusText: String {
        if model.crashCopyReviewRequired { return "Crash-copy review required" }
        if model.postResetReviewRequired { return "Hello-screen review required" }
        if model.operationRunning { return model.operationStep.isEmpty ? "Operation in progress" : model.operationStep }
        if model.isMonitoring { return "Watching USB mode changes" }
        if model.snapshot.deviceCount == 0 { return "No iPhone detected" }
        if model.snapshot.deviceCount > 1 { return "Multiple devices detected" }
        return "\(compactModeTitle) • \(model.snapshot.modeVerified ? "protocol verified" : "USB evidence only")"
    }

    private var footerStatusColor: Color {
        if model.crashCopyReviewRequired || model.snapshot.deviceCount > 1 { return .red }
        if model.postResetReviewRequired || model.snapshot.mode == .restoreOS || model.snapshot.mode == .usbUnavailable { return .orange }
        if model.snapshot.mode == .normal && model.snapshot.modeVerified { return .green }
        return modeColor
    }

    private func select(_ destination: AppSidebarDestination) {
        selectedDestination = destination
        selectedSection = destination.workspace
    }

    private func cycleAppearance() {
        switch appearancePreference {
        case "system": appearancePreference = "light"
        case "light": appearancePreference = "dark"
        default: appearancePreference = "system"
        }
    }

    private var statusBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: statusIcon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(statusAccentColor)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                if let statusEyebrow {
                    Text(statusEyebrow)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusAccentColor)
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(model.statusText)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.isScanning {
                        ProgressView().controlSize(.small)
                    }
                }

                Text(model.detailText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.operationRunning {
                    VStack(alignment: .leading, spacing: 5) {
                        if let progress = model.progress {
                            ProgressView(value: progress)
                        } else {
                            ProgressView()
                        }
                        Text(model.operationStep)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 3)
                }

                if let error = model.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 12)

            Text(statusBadgeTitle)
                .font(.caption.weight(.medium))
                .foregroundStyle(statusAccentColor)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(statusAccentColor.opacity(statusTintOpacity))
                )
                .fixedSize()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(statusAccentColor.opacity(statusTintOpacity))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(statusAccentColor.opacity(0.28), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("statusPanel")
    }

    private func twoColumnBody(width: CGFloat) -> some View {
        let railWidth = min(max(width * 0.34, 300), 320)
        return HStack(alignment: .top, spacing: 0) {
            ScrollView {
                leftRail
                    .padding(.leading, 20)
                    .padding(.trailing, 14)
                    .padding(.vertical, 16)
            }
            .frame(width: railWidth)
            .accessibilityIdentifier("identityRail")

            Divider()

            ScrollView {
                actionColumn
                    .padding(.leading, 16)
                    .padding(.trailing, 20)
                    .padding(.vertical, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("actionColumn")
        }
    }

    private func twoColumnFullContent(width: CGFloat) -> some View {
        let railWidth = min(max(width * 0.34, 300), 320)
        return HStack(alignment: .top, spacing: 0) {
            leftRail
                .padding(.leading, 20)
                .padding(.trailing, 14)
                .padding(.vertical, 16)
                .frame(width: railWidth)

            Divider()

            actionColumn
                .padding(.leading, 16)
                .padding(.trailing, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var stackedBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                leftRail
                actionColumn
            }
            .padding(16)
        }
        .accessibilityIdentifier("stackedContent")
    }

    private var leftRail: some View {
        VStack(alignment: .leading, spacing: 12) {
            targetIdentityCard
            readinessCard
            logCard
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var targetIdentityCard: some View {
        let displaySnapshot = targetDisplaySnapshot
        return UtilityCard(title: "Target identity", systemImage: "iphone") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                evidenceRow("Mode", compactModeTitle)
                evidenceRow(
                    "Protocol",
                    displaySnapshot.deviceCount == 0
                        ? "—"
                        : (displaySnapshot.modeVerified ? "Verified" : "USB evidence only")
                )
                evidenceRow("Product", displaySnapshot.productType ?? "—")
                evidenceRow("Hardware", displaySnapshot.hardwareModel ?? "—")
                evidenceRow("iOS / Build", versionBuild)
                evidenceRow("Activation", displaySnapshot.activationState ?? "—")
                evidenceRow("USB PID", displaySnapshot.pidHex, monospaced: true)
            }

            Divider()

            identifierRow(
                "ECID",
                maskTargetIdentifier(displaySnapshot.displayECID)
            )
            identifierRow("UDID", maskTargetIdentifier(displaySnapshot.displayUDID))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("targetIdentityPanel")
    }

    private var readinessCard: some View {
        let doctor = model.dependencyDoctorSnapshot
        return UtilityCard(title: "System readiness", systemImage: "checkmark.shield") {
            if let mobile = doctor.component(.libimobiledevice) {
                dependencyRow(mobile)
            }
            if let recovery = doctor.component(.libirecovery) {
                dependencyRow(recovery)
            }
            if let configurator = doctor.component(.appleConfigurator) {
                dependencyRow(configurator)
            }

            DisclosureGroup(isExpanded: $isDependencyDoctorExpanded) {
                VStack(alignment: .leading, spacing: 9) {
                    if let homebrew = doctor.component(.homebrew) {
                        dependencyRow(homebrew)
                    }

                    Divider()

                    Text("Built-in tools are preferred and Homebrew is not required. Apple Configurator remains an optional Apple-installed component for Revive, Restore, and Factory Reset.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(doctor.capabilities, id: \.capability) { capability in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Image(systemName: capability.isAvailable ? "checkmark.circle" : "minus.circle")
                                .foregroundStyle(capability.isAvailable ? Color.green : Color.secondary)
                                .accessibilityHidden(true)
                            Text(capability.capability.rawValue)
                                .font(.caption)
                            Spacer(minLength: 6)
                            Text(capability.isAvailable ? "Ready" : "Unavailable")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 8)
            } label: {
                Text("Dependency Doctor")
                    .font(.callout.weight(.medium))
            }
            .accessibilityIdentifier("dependencyDoctorDisclosure")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("systemReadinessPanel")
    }

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isLogExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .foregroundStyle(.secondary)
                        Text("Diagnostic log")
                            .font(.headline)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isLogExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isLogExpanded ? "Collapse diagnostic log" : "Expand diagnostic log")
                .accessibilityIdentifier("diagnosticLogToggle")

                Spacer(minLength: 8)

                Button("Save…") { model.saveLog() }
                    .controlSize(.small)
                    .accessibilityIdentifier("saveLogButton")
            }

            if isLogExpanded {
                Text("ECID and UDID are masked in exported logs")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ScrollViewReader { proxy in
                    ScrollView {
                        Text(model.logText.isEmpty ? "No log entries yet." : model.logText)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .id("log-end")
                    }
                    .frame(minHeight: 105, maxHeight: 150)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
                    )
                    .onReceive(model.$logText) { _ in
                        proxy.scrollTo("log-end", anchor: .bottom)
                    }
                }
            }
        }
        .utilityCardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("diagnosticLogPanel")
    }

    private var actionColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            recommendedActionCard

            if showsButtonGuide {
                buttonGuide
            }

            if model.snapshot.mode == .normal {
                factoryResetCard
                restoreCard
            } else {
                restoreCard
                factoryResetCard
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recommendedActionCard: some View {
        UtilityCard(title: "Recommended next action", systemImage: "arrow.right.circle.fill", accent: .blue) {
            AdaptiveActionRow {
                Text(recommendedActionDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } trailing: {
                HStack(spacing: 8) {
                    Button(model.primaryActionTitle) {
                        model.performPrimaryAction()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.primaryActionEnabled)
                    .accessibilityIdentifier("primaryActionButton")

                    if model.isMonitoring {
                        Button("Stop watcher") {
                            model.stopMonitoring()
                        }
                        .controlSize(.large)
                        .accessibilityIdentifier("stopWatcherButton")
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recommendedActionPanel")
    }

    private var recommendedActionDetail: String {
        if model.postResetReviewRequired {
            return "Confirm the iPhone screen before scanning again. All write actions remain locked until this manual check."
        }
        switch model.snapshot.mode {
        case .normal:
            return "Use the safe Recovery transition for firmware repair, or choose the separate Factory Reset path below."
        case .restoreOS:
            return "Start the live USB watcher, then follow the physical Recovery sequence below."
        case .recovery:
            return "Try Apple Revive first; it does not automatically fall through to an erase."
        case .dfu:
            return "DFU is confirmed. Review firmware and the destructive Restore path below."
        case .usbUnavailable, .unknown:
            return "Re-scan or start the physical guide; write actions stay disabled until the mode and identity are verified."
        case .notDetected:
            return "Connect one iPhone directly with a data-capable cable, then scan."
        case .multiple:
            return "Disconnect every extra Apple mobile device before continuing."
        }
    }

    private var buttonGuide: some View {
        UtilityCard(title: "Physical button guide", systemImage: "hand.tap") {
            Text("Try Recovery first")
                .font(.subheadline.weight(.semibold))

            VStack(alignment: .leading, spacing: 9) {
                guideStep(1, "Keep the cable connected.")
                guideStep(2, "Quick press Volume Up.")
                guideStep(3, "Quick press Volume Down.")
                guideStep(4, "Hold the Side button through the black screen and Apple logo. Release only when the Connect-to-computer screen appears.")
            }

            Divider()

            DisclosureGroup(isExpanded: $isDFUExpanded) {
                Text("Quick Volume Up → quick Volume Down → hold Side until the screen turns fully black. Immediately hold Side + Volume Down together for 5 seconds. Release Side only; keep holding Volume Down for about 10 seconds. The screen must stay black. Stop as soon as the app reports DFU.")
                    .font(.callout)
                    .padding(.top, 8)
                    .fixedSize(horizontal: false, vertical: true)
            } label: {
                Text("If Recovery still will not appear: DFU timing")
                    .font(.subheadline.weight(.medium))
            }
            .accessibilityIdentifier("dfuTimingDisclosure")

            Text("RestoreOS returning usually means the timing was missed. A Recovery PID 0x1280–0x1283 or DFU PID 0x1227 must appear, then irecovery plus the matching ECID and SE2 identity must verify the mode before Restore is enabled.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("physicalButtonGuidePanel")
    }

    private func guideStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(String(number))
                .font(.caption.weight(.bold))
                .foregroundStyle(.blue)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.blue.opacity(colorScheme == .dark ? 0.20 : 0.10)))
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(number): \(text)")
    }

    private var restoreCard: some View {
        UtilityCard(title: "Firmware and recovery", systemImage: "arrow.triangle.2.circlepath") {
            AdaptiveActionRow {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.selectedIPSW?.title ?? "Latest currently signed iOS from Apple")
                        .font(.subheadline.weight(.semibold))
                    Text(model.selectedIPSW == nil
                         ? "Apple Configurator downloads the official firmware."
                         : "BuildManifest compatibility checked for iPhone12,8: \(model.selectedIPSW?.url.lastPathComponent ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } trailing: {
                HStack(spacing: 8) {
                    Menu("Firmware") {
                        Button("Use Apple latest") { model.useAppleLatest() }
                        Button("Use Configurator cache…") { model.useConfiguratorCache() }
                        Button("Choose IPSW…") { model.chooseIPSW() }
                    }
                    .disabled(!model.canChooseIPSW)
                    .accessibilityIdentifier("firmwareMenu")

                    if model.isValidatingFirmware {
                        ProgressView().controlSize(.small)
                    }
                }
            }

            Divider()

            AdaptiveActionRow {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "shield.checkered")
                        .foregroundStyle(.blue)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Preserve data — Apple Revive")
                            .font(.subheadline.weight(.semibold))
                        Text("Recovery Mode only. Attempts repair without automatically erasing data.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } trailing: {
                Button("Try Revive") { model.performPrimaryAction() }
                    .disabled(!model.canRevive)
                    .accessibilityIdentifier("reviveButton")
            }

            Divider()

            AdaptiveActionRow {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Erase and reinstall iOS")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.red)
                        Text("One verified SE2 in Recovery/DFU only. Close Finder device operations; typed ERASE and a final ECID check are required.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } trailing: {
                Button("Erase & Restore…") { model.startRestore() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(!model.canRestore)
                    .help("Permanently erases the iPhone and installs official Apple firmware")
                    .accessibilityIdentifier("restoreButton")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recoveryPanel")
    }

    private var factoryResetCard: some View {
        UtilityCard(
            title: "Factory Reset — Erase All Content & Settings",
            systemImage: "trash.fill",
            accent: model.snapshot.mode == .normal ? .red : nil
        ) {
            AdaptiveActionRow {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Permanently deletes user data and settings while keeping the current iOS version. It does not reinstall firmware or request eSIM deletion.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Label("Required before starting: unlock, verify Trust/activation, and manually sign out of Find My. The app cannot verify Find My status.", systemImage: "checklist")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if model.snapshot.mode != .normal {
                        Label("Unavailable in the current mode; use the recovery path above.", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } trailing: {
                Button("Factory Reset…") { model.startFactoryReset() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(!model.canFactoryReset)
                    .help("Permanently erases content and settings without reinstalling iOS")
                    .accessibilityIdentifier("factoryResetButton")
            }

            Text("This cannot repair RestoreOS, Recovery, or DFU. Exact target, Trust, supervision, and typed confirmation checks run again immediately before erase.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("factoryResetPanel")
    }

    private var versionBuild: String {
        let version = targetDisplaySnapshot.productVersion ?? "—"
        guard let build = targetDisplaySnapshot.buildVersion else { return version }
        return "\(version) (\(build))"
    }

    private var targetDisplaySnapshot: DeviceSnapshot {
        model.postResetReviewRequired
            ? DeviceCenterCollector.postMutationDeviceEvidence(for: model.snapshot)
            : model.snapshot
    }

    private func evidenceRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(.caption, design: .monospaced) : .callout)
                .textSelection(.enabled)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func identifierRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func maskTargetIdentifier(_ value: String) -> String {
        value == "—" ? value : DeviceCenterPrivacy.maskIdentifier(value)
    }

    private func readinessRow(_ available: Bool, title: String, detail: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: available ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(available ? Color.green : Color.red)
                .accessibilityHidden(true)
            Text(title)
                .font(.callout)
            Spacer(minLength: 6)
            Text(detail)
                .font(.caption.weight(.medium))
                .foregroundStyle(available ? Color.green : Color.red)
                .multilineTextAlignment(.trailing)
        }
    }

    private func dependencyRow(_ status: DependencyComponentStatus) -> some View {
        let available = status.health == .ready || status.health == .notRequired
        let color: Color = {
            switch status.health {
            case .ready, .notRequired: return .green
            case .degraded: return .orange
            case .missing: return status.requirement == .advancedAppleOperations ? .orange : .red
            }
        }()
        let detail = [status.sourceSummary, status.version.map { "v\($0)" }]
            .compactMap { $0 }
            .joined(separator: " • ")

        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: available ? "checkmark.circle.fill" : (status.health == .degraded ? "exclamationmark.circle.fill" : "minus.circle.fill"))
                .foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.component.title)
                    .font(.callout)
                Text(status.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Text(detail)
                .font(.caption.weight(.medium))
                .foregroundStyle(color)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct UtilityCard<Content: View>: View {
    let title: String
    let systemImage: String
    let accent: Color?
    let content: Content

    init(
        title: String,
        systemImage: String,
        accent: Color? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.accent = accent
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(accent ?? Color.primary)
            content
        }
        .utilityCardSurface(accent: accent)
    }
}

private struct AdaptiveActionRow<Leading: View, Trailing: View>: View {
    let leading: Leading
    let trailing: Trailing

    init(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                leading
                Spacer(minLength: 12)
                trailing
                    .fixedSize(horizontal: true, vertical: false)
            }

            VStack(alignment: .leading, spacing: 10) {
                leading
                trailing
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension View {
    func utilityCardSurface(accent: Color? = nil) -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(accent?.opacity(0.055) ?? Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        accent?.opacity(0.28) ?? Color(nsColor: .separatorColor).opacity(0.48),
                        lineWidth: 1
                    )
            )
    }
}
