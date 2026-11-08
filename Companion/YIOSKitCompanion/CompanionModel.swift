import CoreLocation
import Foundation
import MapKit

struct SavedPlace: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var latitude: Double
    var longitude: Double

    init(id: UUID = UUID(), name: String, latitude: Double, longitude: Double) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var coordinateText: String {
        String(format: "%.5f, %.5f", locale: Locale(identifier: "en_US_POSIX"), latitude, longitude)
    }

    static let yangon = SavedPlace(
        id: UUID(uuidString: "10A005A3-2409-48FA-9F4D-5A80AD8DCDA1")!,
        name: "Yangon", latitude: 16.8409, longitude: 96.1735
    )

    static let defaults = [
        yangon,
        SavedPlace(id: UUID(uuidString: "18C0845E-467A-448A-A4CB-5F40765D6A6C")!,
                   name: "Singapore", latitude: 1.3521, longitude: 103.8198),
        SavedPlace(id: UUID(uuidString: "DC2316CE-243B-46F3-A069-18B822C7DE88")!,
                   name: "Tokyo", latitude: 35.6762, longitude: 139.6503)
    ]

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        name.count <= 100 && latitude.isFinite && longitude.isFinite &&
        (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

@MainActor
final class SavedPlacesStore: ObservableObject {
    @Published private(set) var places: [SavedPlace]
    @Published var selectedPlace: SavedPlace
    @Published private(set) var storageMessage: String?
    private let defaults: UserDefaults
    private static let storageKey = "savedPlaces.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let restored: [SavedPlace]
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([SavedPlace].self, from: data),
           decoded.count <= 200, decoded.allSatisfy(\.isValid),
           Set(decoded.map(\.id)).count == decoded.count {
            restored = decoded
        } else {
            restored = SavedPlace.defaults
        }
        places = restored
        selectedPlace = restored.first ?? .yangon
    }

    @discardableResult
    func add(name: String, latitude: String, longitude: String) -> Bool {
        guard places.count < 200,
              let lat = Double(latitude.trimmingCharacters(in: .whitespacesAndNewlines)),
              let lon = Double(longitude.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        let place = SavedPlace(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                               latitude: lat, longitude: lon)
        guard place.isValid else { return false }
        places.append(place)
        selectedPlace = place
        persist()
        return true
    }

    func remove(_ place: SavedPlace) {
        places.removeAll { $0.id == place.id }
        if selectedPlace.id == place.id { selectedPlace = places.first ?? .yangon }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(places) else {
            storageMessage = "This place could not be saved."
            return
        }
        defaults.set(data, forKey: Self.storageKey)
        storageMessage = nil
    }
}

@MainActor
final class PhoneLocationReader: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var authorization: CLAuthorizationStatus
    @Published private(set) var latestLocation: CLLocation?
    @Published private(set) var isReading = false
    @Published private(set) var message = "Your location is read only when you request it."
    private let manager = CLLocationManager()
    private var requestedLocation = false

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var permissionLabel: String {
        switch authorization {
        case .authorizedAlways, .authorizedWhenInUse: return "Allowed while using the app"
        case .denied: return "Not allowed"
        case .restricted: return "Restricted by this iPhone"
        case .notDetermined: return "Not requested"
        @unknown default: return "Unknown"
        }
    }

    func readOnce() {
        guard !isReading else { return }
        switch authorization {
        case .notDetermined:
            requestedLocation = true
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            isReading = true
            message = "Reading the location reported by iOS…"
            manager.requestLocation()
        case .denied, .restricted:
            message = "Allow location access in iPhone Settings to read the location reported by iOS."
        @unknown default:
            message = "Location access is unavailable."
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        if requestedLocation {
            requestedLocation = false
            readOnce()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        isReading = false
        guard let location = locations.last, location.horizontalAccuracy >= 0 else {
            message = "iOS has not returned a usable location yet."
            return
        }
        latestLocation = location
        message = "Reported by iOS · accuracy about \(Int(location.horizontalAccuracy.rounded())) m"
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        isReading = false
        message = "A location is not available right now. Try again outdoors or check Location Services."
    }
}
