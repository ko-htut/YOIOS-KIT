import CoreLocation
import Foundation
import SwiftUI
import UIKit

struct CompanionMockLocationView: View {
    var body: some View {
#if targetEnvironment(simulator)
        SimulatorMockLocationView()
#else
        NavigationStack {
            List {
                Section {
                    Label("Phone connection is not available yet", systemImage: "iphone.and.arrow.forward")
                        .font(.headline)
                    Text("The companion's Mock Location controls are being tested in Simulator first. They do not change a physical iPhone's location in this version.")
                        .foregroundStyle(.secondary)
                }
                Section("Use the Mac app") {
                    Text("Connect this iPhone to YIOS-KIT on your Mac and use its Mock Location page. Pairing, Developer Mode, and the exact phone are checked there before a location request is sent.")
                    Text("Installing this companion does not preserve a simulated location through an iPhone restart.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Mock Location")
            .accessibilityIdentifier("physicalMockLocationUnavailable")
        }
#endif
    }
}

#if targetEnvironment(simulator)
struct SimulatorBridgeConfiguration {
    let baseURL: URL
    let token: String
    let sessionID: UUID
    let simulatorID: UUID

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self? {
        guard let raw = environment["YIOS_SIMULATOR_BRIDGE_CONFIG"], raw.utf8.count <= 2_048,
              let bytes = raw.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let version = values["protocol"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
              let address = values["baseURL"] as? String,
              let parts = URLComponents(string: address), parts.scheme == "http", parts.host == "127.0.0.1",
              let port = parts.port, (1...65_535).contains(port),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/", let baseURL = parts.url,
              let token = values["token"] as? String,
              token.range(of: #"^[0-9a-fA-F]{64}$"#, options: .regularExpression) != nil,
              let rawSession = values["sessionID"] as? String, let sessionID = UUID(uuidString: rawSession),
              let rawSimulator = values["simulatorID"] as? String, let simulatorID = UUID(uuidString: rawSimulator),
              let actual = environment["SIMULATOR_UDID"], UUID(uuidString: actual) == simulatorID else { return nil }
        return Self(baseURL: baseURL, token: token, sessionID: sessionID, simulatorID: simulatorID)
    }
}

enum SimulatorBridgeState: String, Decodable {
    case idle, setAccepted, clearAccepted, uncertain
}

private struct SimulatorBridgeReply: Decodable {
    let `protocol`: Int
    let sessionID: UUID
    let simulatorID: UUID
    let state: SimulatorBridgeState
    let revision: Int
    let requestID: UUID?
    let operation: String?
    let acknowledgement: String?
}

private enum SimulatorBridgeError: Error {
    case unavailable, invalidReply, uncertain
}

private final class SimulatorBridgeSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class SimulatorMockLocationController: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var isBusy = false
    @Published private(set) var isVerifying = false
    @Published private(set) var commandStatus = "Simulator bridge is not configured"
    @Published private(set) var detail = "Start the simulator bridge on your Mac, then launch this simulator app with its private session configuration."
    @Published private(set) var readbackStatus = "Not checked"
    @Published private(set) var observedCoordinate: String?
    @Published private(set) var observedAt: Date?
    @Published private(set) var softwareSource = "Not checked"
    @Published private(set) var isVerified = false
    @Published private(set) var remoteState: SimulatorBridgeState?
    @Published private(set) var errorMessage: String?

    private let configuration: SimulatorBridgeConfiguration?
    private let manager = CLLocationManager()
    private let session: URLSession
    private var expectedCoordinate: CLLocationCoordinate2D?
    private var readStartedAt: Date?
    private var pendingVerification = false
    private var setAcknowledged = false
    private var matchingSample: CLLocation?
    private var verificationDeadline: Task<Void, Never>?
    private var authorizationDeadline: Task<Void, Never>?
    private var authorizationContinuation: CheckedContinuation<Bool, Never>?
    private var revision: Int?
    private var isInForeground = true

    var isConfigured: Bool { configuration != nil }
    var canSet: Bool { isConfigured && !isBusy && !isVerifying && remoteState != .uncertain }
    var canClear: Bool { isConfigured && !isBusy }
    var canVerify: Bool { !isBusy && !isVerifying && setAcknowledged && expectedCoordinate != nil }
    var verificationState: String {
        if isVerified { return "verified" }
        if remoteState == .clearAccepted { return "cleared" }
        return "unverified"
    }

    override init() {
        configuration = SimulatorBridgeConfiguration.load()
        let options = URLSessionConfiguration.ephemeral
        options.timeoutIntervalForRequest = 25
        options.timeoutIntervalForResource = 30
        options.waitsForConnectivity = false
        options.httpShouldSetCookies = false
        options.urlCache = nil
        options.urlCredentialStorage = nil
        session = URLSession(configuration: options, delegate: SimulatorBridgeSessionDelegate(), delegateQueue: nil)
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        if configuration != nil {
            commandStatus = "Ready to check the simulator bridge"
            detail = "Only this explicitly selected simulator can be changed. A command acknowledgement and the location reported by Core Location are shown separately."
        }
    }

    static func coordinate(latitude: String, longitude: String) -> CLLocationCoordinate2D? {
        guard let lat = Double(latitude.trimmingCharacters(in: .whitespacesAndNewlines)),
              let lon = Double(longitude.trimmingCharacters(in: .whitespacesAndNewlines)),
              lat.isFinite, lon.isFinite, (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    func refresh() async {
        guard isConfigured, !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let reply = try await request(path: "status")
            if (revision != nil && revision != reply.revision) ||
                (remoteState != nil && remoteState != reply.state) { resetReadback() }
            revision = reply.revision
            remoteState = reply.state
            switch reply.state {
            case .idle:
                commandStatus = "Simulator bridge connected"
                detail = "No location request is recorded in this bridge session."
            case .setAccepted:
                commandStatus = "Simulator override recorded by the Mac"
                detail = "Set a coordinate to obtain a fresh readback, or clear the simulator override. Relaunching this app never resends a saved location."
            case .clearAccepted:
                commandStatus = "Clear accepted by the Mac"
                detail = "The simulator override was cleared. A simulator has no physical GPS, so this is not proof of a real-world location."
            case .uncertain:
                resetReadback()
                commandStatus = "Simulator request needs review"
                detail = "The prior request could not be verified. Clear the override before setting a new coordinate."
            }
        } catch {
            resetReadback()
            errorMessage = "The local simulator bridge could not be checked. Keep the Mac bridge running and check its session configuration."
        }
    }

    func set(latitude: String, longitude: String) async {
        guard canSet else { return }
        guard let coordinate = Self.coordinate(latitude: latitude, longitude: longitude) else {
            errorMessage = "Enter finite latitude from −90 to 90 and longitude from −180 to 180."
            return
        }
        resetReadback()
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        commandStatus = "Checking location permission…"
        detail = "Allow location access before the request so Core Location is listening when the simulator changes."
        guard await ensureReadbackAuthorization(), isInForeground, !Task.isCancelled else {
            expectedCoordinate = nil
            commandStatus = "Location permission is required"
            detail = "No Set request was sent. Allow location access for YIOS-KIT in this simulator's Settings, then try again."
            errorMessage = "Permission was denied, cancelled, or did not complete within 30 seconds."
            readbackStatus = "Not checked — no Set request was sent"
            return
        }
        expectedCoordinate = coordinate
        beginVerification()
        commandStatus = "Sending simulator location request…"
        let requestID = UUID()
        do {
            let reply = try await request(path: "set", requestID: requestID,
                                          coordinate: coordinate)
            revision = reply.revision
            remoteState = reply.state
            setAcknowledged = true
            commandStatus = "Set accepted by the Mac"
            detail = "Apple's simulator tool accepted the coordinate. Waiting for a fresh Core Location sample before calling it verified."
            if isInForeground {
                if isVerifying {
                    if let sample = matchingSample {
                        if Date().timeIntervalSince(sample.timestamp) <= 5 { recordVerified(sample) }
                        else { beginVerification() }
                    }
                } else {
                    beginVerification()
                }
            }
        } catch {
            resetReadback()
            remoteState = .uncertain
            commandStatus = "Set completion is uncertain"
            detail = "The request may have reached the simulator. It will not be retried automatically. Clear the override or check the Mac bridge."
            errorMessage = "No verified location result is available."
            readbackStatus = "Unverified — Set completion is uncertain"
        }
    }

    func clear() async {
        guard canClear else { return }
        resetReadback()
        expectedCoordinate = nil
        isBusy = true
        errorMessage = nil
        commandStatus = "Clearing simulator location…"
        defer { isBusy = false }
        do {
            let reply = try await request(path: "clear", requestID: UUID())
            revision = reply.revision
            remoteState = reply.state
            commandStatus = "Clear accepted by the Mac"
            detail = "The simulator override was cleared. Previously observed coordinates were discarded; this does not claim a physical GPS reading."
        } catch {
            remoteState = .uncertain
            commandStatus = "Clear completion is uncertain"
            detail = "Keep the Mac bridge running and check the simulator before trying another location. Clear was not automatically retried."
            errorMessage = "The simulator clear could not be verified."
        }
    }

    func verifyAgain() {
        guard canVerify else { return }
        beginVerification()
    }

    func suspendReadback() {
        isInForeground = false
        completeAuthorization(false)
        stopVerification()
        isVerified = false
        matchingSample = nil
        observedCoordinate = nil
        observedAt = nil
        softwareSource = "Not checked"
        readbackStatus = "Verify again for a fresh sample after returning to the app"
    }

    func resumeReadback() async {
        guard !isInForeground else { return }
        isInForeground = true
        await refresh()
    }

    private func ensureReadbackAuthorization() async -> Bool {
        guard !Task.isCancelled else { return false }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard !Task.isCancelled else { continuation.resume(returning: false); return }
                    authorizationContinuation = continuation
                    authorizationDeadline = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 30_000_000_000)
                        guard !Task.isCancelled else { return }
                        self?.completeAuthorization(false)
                    }
                    manager.requestWhenInUseAuthorization()
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.completeAuthorization(false) }
            }
        @unknown default: return false
        }
    }

    private func completeAuthorization(_ allowed: Bool) {
        authorizationDeadline?.cancel()
        authorizationDeadline = nil
        let continuation = authorizationContinuation
        authorizationContinuation = nil
        continuation?.resume(returning: allowed)
    }

    private func request(path: String, requestID: UUID? = nil,
                         coordinate: CLLocationCoordinate2D? = nil) async throws -> SimulatorBridgeReply {
        guard let configuration else { throw SimulatorBridgeError.unavailable }
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("v1").appendingPathComponent(path))
        request.setValue("Bearer " + configuration.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 25
        if let requestID {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body: [String: Any] = ["requestID": requestID.uuidString]
            if let coordinate { body["latitude"] = coordinate.latitude; body["longitude"] = coordinate.longitude }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, data.count <= 32_768,
              http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("application/json") == true,
              http.statusCode == 200,
              let reply = try? JSONDecoder().decode(SimulatorBridgeReply.self, from: data),
              reply.protocol == 1, reply.sessionID == configuration.sessionID,
              reply.simulatorID == configuration.simulatorID, reply.revision >= 0 else {
            throw SimulatorBridgeError.invalidReply
        }
        if let requestID {
            guard reply.requestID == requestID, reply.operation == path,
                  reply.acknowledgement == "accepted",
                  reply.state == (path == "set" ? .setAccepted : .clearAccepted) else {
                throw SimulatorBridgeError.uncertain
            }
        }
        return reply
    }

    private func resetReadback() {
        stopVerification()
        isVerified = false
        setAcknowledged = false
        matchingSample = nil
        observedCoordinate = nil
        observedAt = nil
        softwareSource = "Not checked"
        readbackStatus = "Not checked"
    }

    private func beginVerification() {
        stopVerification()
        isVerified = false
        matchingSample = nil
        observedCoordinate = nil
        observedAt = nil
        softwareSource = "Not checked"
        guard isInForeground else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            pendingVerification = true
            readbackStatus = "Allow location access to verify the simulator result"
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            guard expectedCoordinate != nil else { return }
            isVerifying = true
            readStartedAt = Date()
            readbackStatus = "Waiting for a fresh Core Location sample…"
            manager.startUpdatingLocation()
            verificationDeadline = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled, let self, self.isVerifying else { return }
                self.stopVerification()
                self.matchingSample = nil
                self.readbackStatus = "No fresh matching simulated location was returned"
            }
        case .denied, .restricted:
            readbackStatus = "Location permission is required for readback verification"
        @unknown default:
            readbackStatus = "Location permission is unavailable"
        }
    }

    private func stopVerification() {
        pendingVerification = false
        verificationDeadline?.cancel()
        verificationDeadline = nil
        manager.stopUpdatingLocation()
        isVerifying = false
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if authorizationContinuation != nil && manager.authorizationStatus != .notDetermined {
            completeAuthorization(manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse)
        }
        if pendingVerification {
            pendingVerification = false
            beginVerification()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isVerifying, let expectedCoordinate, let readStartedAt else { return }
        let freshSamples = locations.filter { sample in
            let coordinate = sample.coordinate
            return coordinate.latitude.isFinite && coordinate.longitude.isFinite &&
                CLLocationCoordinate2DIsValid(coordinate) && sample.horizontalAccuracy.isFinite &&
                sample.horizontalAccuracy >= 0 && sample.timestamp >= readStartedAt &&
                sample.timestamp <= Date().addingTimeInterval(2)
        }
        guard let sample = freshSamples.max(by: { $0.timestamp < $1.timestamp }) else { return }
        // A newer contradictory sample must replace a pre-acknowledgement
        // match, rather than leaving an earlier match eligible for success.
        matchingSample = nil
        observedCoordinate = String(format: "%.5f, %.5f", locale: Locale(identifier: "en_US_POSIX"),
                                    sample.coordinate.latitude, sample.coordinate.longitude)
        observedAt = sample.timestamp
        let simulated = sample.sourceInformation?.isSimulatedBySoftware
        softwareSource = simulated == true ? "Software simulation reported by iOS" : "Software simulation source not confirmed"
        let target = CLLocation(latitude: expectedCoordinate.latitude, longitude: expectedCoordinate.longitude)
        guard sample.distance(from: target) <= 20 else {
            readbackStatus = "A fresh location was returned, but it does not match the requested coordinate"
            return
        }
        guard simulated == true else {
            readbackStatus = "Fresh coordinate matches; iOS did not confirm the simulation source"
            return
        }
        matchingSample = sample
        if setAcknowledged { recordVerified(sample) }
    }

    private func recordVerified(_ sample: CLLocation) {
        guard isInForeground, isVerifying, let readStartedAt, let expectedCoordinate,
              sample.timestamp >= readStartedAt,
              Date().timeIntervalSince(sample.timestamp) <= 5,
              sample.timestamp <= Date().addingTimeInterval(2),
              sample.sourceInformation?.isSimulatedBySoftware == true,
              sample.coordinate.latitude.isFinite, sample.coordinate.longitude.isFinite,
              CLLocationCoordinate2DIsValid(sample.coordinate),
              sample.horizontalAccuracy.isFinite, sample.horizontalAccuracy >= 0,
              sample.distance(from: CLLocation(latitude: expectedCoordinate.latitude,
                                               longitude: expectedCoordinate.longitude)) <= 20,
              manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse else { return }
        isVerified = true
        readbackStatus = "Verified by Core Location"
        detail = "A fresh location is within 20 metres of the requested coordinate, and iOS reports it as software simulated."
        observedCoordinate = String(format: "%.5f, %.5f", locale: Locale(identifier: "en_US_POSIX"),
                                    sample.coordinate.latitude, sample.coordinate.longitude)
        observedAt = sample.timestamp
        stopVerification()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard isVerifying else { return }
        if (error as? CLError)?.code == .locationUnknown { return }
        stopVerification()
        readbackStatus = "Core Location could not return a fresh sample"
    }
}

private struct SimulatorMockLocationView: View {
    @EnvironmentObject private var places: SavedPlacesStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller = SimulatorMockLocationController()
    @State private var latitude = "16.8409"
    @State private var longitude = "96.1735"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Simulator testing", systemImage: "desktopcomputer")
                        .font(.headline).foregroundStyle(.blue)
                    Text("These controls change this simulator's system location through a local bridge on your Mac. They cannot target a physical iPhone.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Test coordinate") {
                    Menu {
                        ForEach(places.places) { place in
                            Button(place.name) {
                                latitude = String(place.latitude)
                                longitude = String(place.longitude)
                            }
                        }
                    } label: { Label("Use a saved place", systemImage: "bookmark") }
                    .accessibilityIdentifier("simulatorMockPresetsButton")
                    LabeledContent("Latitude") {
                        TextField("−90 to 90", text: $latitude)
                            .keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("Latitude")
                            .accessibilityIdentifier("simulatorMockLatitudeField")
                    }
                    LabeledContent("Longitude") {
                        TextField("−180 to 180", text: $longitude)
                            .keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("Longitude")
                            .accessibilityIdentifier("simulatorMockLongitudeField")
                    }
                    Button {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        Task { await controller.set(latitude: latitude, longitude: longitude) }
                    } label: {
                        Label("Set Simulator Location", systemImage: "location.fill")
                    }
                    .disabled(!controller.canSet || SimulatorMockLocationController.coordinate(latitude: latitude, longitude: longitude) == nil)
                    .accessibilityIdentifier("simulatorMockSetButton")
                    if SimulatorMockLocationController.coordinate(latitude: latitude, longitude: longitude) == nil {
                        Text("Enter finite latitude from −90 to 90 and longitude from −180 to 180.")
                            .font(.footnote).foregroundStyle(.orange)
                            .accessibilityIdentifier("simulatorMockCoordinateValidation")
                    }
                    Button("Clear Simulator Location", role: .destructive) {
                        Task { await controller.clear() }
                    }
                    .disabled(!controller.canClear)
                    .accessibilityIdentifier("simulatorMockClearButton")
                }
                Section("Mac acknowledgement") {
                    HStack(alignment: .top) {
                        Text(controller.commandStatus).font(.subheadline.weight(.semibold))
                            .accessibilityIdentifier("simulatorMockStatus")
                        Spacer()
                        if controller.isBusy { ProgressView() }
                    }
                    Text(controller.detail).font(.footnote).foregroundStyle(.secondary)
                    if let error = controller.errorMessage {
                        Text(error).font(.footnote).foregroundStyle(.orange)
                            .accessibilityIdentifier("simulatorMockError")
                    }
                    Button("Check Mac Bridge") { Task { await controller.refresh() } }
                        .disabled(!controller.isConfigured || controller.isBusy)
                        .accessibilityIdentifier("simulatorMockRefreshButton")
                }
                Section("Core Location readback") {
                    Text("Verification: \(controller.verificationState)")
                        .font(.caption.weight(.semibold))
                        .accessibilityIdentifier("simulatorMockVerificationState")
                        .accessibilityValue(controller.verificationState)
                    Label(controller.readbackStatus, systemImage: controller.isVerified ? "checkmark.seal.fill" : "location.circle")
                        .foregroundStyle(controller.isVerified ? .green : .primary)
                        .accessibilityIdentifier("simulatorMockReadbackStatus")
                    if let coordinate = controller.observedCoordinate {
                        Text(coordinate).font(.body.monospacedDigit())
                            .accessibilityIdentifier("simulatorMockObservedCoordinate")
                    }
                    if let timestamp = controller.observedAt {
                        Text(timestamp, style: .time).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(controller.softwareSource).font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("simulatorMockSourceEvidence")
                    Button("Verify Again") { controller.verifyAgain() }
                        .disabled(!controller.canVerify)
                        .accessibilityIdentifier("simulatorMockVerifyButton")
                    Text("A successful command alone is not a verified location. Clear discards this app's prior sample; a simulator has no physical GPS to restore.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Mock Location")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
            }
            .accessibilityIdentifier("simulatorMockLocationWorkspace")
            .task { await controller.refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await controller.resumeReadback() } }
                if phase == .background { controller.suspendReadback() }
            }
        }
    }
}
#endif
