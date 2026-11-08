import SwiftUI

@main
struct YIOSCompanionApp: App {
    @StateObject private var places = SavedPlacesStore()
    @StateObject private var location = PhoneLocationReader()

    var body: some Scene {
        WindowGroup {
            CompanionRootView()
                .environmentObject(places)
                .environmentObject(location)
                .tint(.blue)
        }
    }
}
