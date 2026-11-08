import Foundation

@main
struct ModelChecks {
    @MainActor
    static func main() throws {
        let suite = "local.yioskit.companion.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
        }

        let store = SavedPlacesStore(defaults: defaults)
        expect(store.places.count == 3, "New installs need the three starting places.")
        expect(store.selectedPlace == .yangon, "Yangon must be the initial selected place.")
        expect(!store.add(name: "", latitude: "16", longitude: "96"), "An empty name must be rejected.")
        expect(!store.add(name: "Invalid", latitude: "nan", longitude: "96"), "NaN must be rejected.")
        expect(!store.add(name: "Invalid", latitude: "0", longitude: "inf"), "Infinity must be rejected.")
        expect(!store.add(name: "Invalid", latitude: "90.01", longitude: "0"), "Latitude must remain within WGS 84 bounds.")
        expect(!store.add(name: "Invalid", latitude: "0", longitude: "-180.01"), "Longitude must remain within WGS 84 bounds.")
        expect(!store.add(name: "Invalid", latitude: "16,84", longitude: "96.17"), "Ambiguous locale input must be rejected.")
        expect(store.add(name: "  Boundary  ", latitude: "-90", longitude: "180"), "Both boundary coordinates are valid.")
        expect(store.selectedPlace.name == "Boundary", "Surrounding name whitespace should be removed.")

        let relaunched = SavedPlacesStore(defaults: defaults)
        expect(relaunched.places.contains(where: { $0.name == "Boundary" }), "Saved places must survive an app restart.")
        let boundary = relaunched.places.first { $0.name == "Boundary" }!
        relaunched.selectedPlace = boundary
        relaunched.remove(boundary)
        expect(relaunched.selectedPlace == .yangon, "Deleting the selected place needs a usable preview fallback.")
        for place in relaunched.places { relaunched.remove(place) }
        let emptyRelaunch = SavedPlacesStore(defaults: defaults)
        expect(emptyRelaunch.places.isEmpty, "Deleting all places must stay deleted after restart.")
        expect(emptyRelaunch.selectedPlace == .yangon, "An empty list needs a valid standalone preview.")

        defaults.set(Data("invalid JSON".utf8), forKey: "savedPlaces.v1")
        let recovered = SavedPlacesStore(defaults: defaults)
        expect(recovered.places == SavedPlace.defaults, "Malformed saved data must recover without crashing.")
        let bad = [SavedPlace(name: "Outside earth", latitude: 500, longitude: 0)]
        defaults.set(try JSONEncoder().encode(bad), forKey: "savedPlaces.v1")
        expect(SavedPlacesStore(defaults: defaults).places == SavedPlace.defaults,
               "Out-of-range persisted coordinates must not reach the map.")
        print("Companion model checks passed: coordinate validation, persistence, deletion and corrupted storage.")
    }
}
