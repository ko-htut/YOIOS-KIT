import CoreLocation
import MapKit
import SwiftUI
import UIKit

private enum CompanionTab: Hashable { case map, places, mockLocation, help }

struct CompanionRootView: View {
    @State private var tab: CompanionTab = .map

    var body: some View {
        TabView(selection: $tab) {
            LocationMapView()
                .tabItem { Label("Explore", systemImage: "map") }
                .tag(CompanionTab.map)
            SavedPlacesView(onExplore: { tab = .map })
                .tabItem { Label("Saved", systemImage: "bookmark") }
                .tag(CompanionTab.places)
            CompanionMockLocationView()
                .tabItem { Label("Mock Location", systemImage: "location.viewfinder") }
                .tag(CompanionTab.mockLocation)
            CompanionHelpView()
                .tabItem { Label("Companion", systemImage: "iphone.and.arrow.forward") }
                .tag(CompanionTab.help)
        }
    }
}

private struct LocationMapView: View {
    @EnvironmentObject private var places: SavedPlacesStore
    @EnvironmentObject private var location: PhoneLocationReader
    @State private var position: MapCameraPosition = .region(MKCoordinateRegion(
        center: SavedPlace.yangon.coordinate,
        span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
    ))
    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    CompanionWordmark()
                    VStack(alignment: .leading, spacing: 5) {
                        Text("A place for your places.")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Preview a location. Keep it close.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Map(position: $position) {
                        Marker(places.selectedPlace.name, coordinate: places.selectedPlace.coordinate)
                            .tint(.blue)
                        if let current = location.latestLocation {
                            Annotation("Reported by iOS", coordinate: current.coordinate) {
                                ZStack {
                                    Circle().fill(.blue.opacity(0.15)).frame(width: 34, height: 34)
                                    Circle().fill(.blue).frame(width: 15, height: 15)
                                        .overlay(Circle().stroke(.white, lineWidth: 3))
                                }
                                .accessibilityLabel("Location reported by iOS")
                            }
                        }
                    }
                    .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
                    .mapControls { MapCompass(); MapScaleView() }
                    .frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .overlay(alignment: .topLeading) {
                        Label("PLACE PREVIEW", systemImage: "mappin")
                            .font(.system(size: 10, weight: .bold)).tracking(0.8)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule())
                            .padding(14)
                    }
                    .accessibilityIdentifier("companionMapPreview")

                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.title).foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(places.selectedPlace.name).font(.title3.weight(.semibold))
                                Text(places.selectedPlace.coordinateText)
                                    .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            ShareLink(item: "\(places.selectedPlace.name): \(places.selectedPlace.coordinateText)") {
                                Image(systemName: "square.and.arrow.up").font(.body.weight(.semibold))
                            }
                            .accessibilityLabel("Share this place")
                        }
                        Divider()
                        Text("This pin previews a saved place. It does not change your iPhone’s location.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .companionCard()

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Reported by iOS", systemImage: "location.circle")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            if location.isReading { ProgressView().controlSize(.small) }
                        }
                        if let current = location.latestLocation {
                            Text(String(format: "%.5f, %.5f", locale: Locale(identifier: "en_US_POSIX"),
                                        current.coordinate.latitude, current.coordinate.longitude))
                                .font(.body.monospacedDigit())
                            Text(current.timestamp, style: .time).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(location.message).font(.footnote).foregroundStyle(.secondary)
                        Button {
                            location.readOnce()
                        } label: {
                            Label("Read iPhone Location", systemImage: "location")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).disabled(location.isReading)
                        .accessibilityIdentifier("readPhoneLocationButton")
                    }
                    .companionCard()
                }
                .padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add Place", systemImage: "plus") { showingAdd = true }
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .onAppear {
                position = .region(MKCoordinateRegion(center: places.selectedPlace.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)))
            }
            .onChange(of: places.selectedPlace) { _, place in
                withAnimation(.easeInOut(duration: 0.35)) {
                    position = .region(MKCoordinateRegion(center: place.coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)))
                }
            }
            .sheet(isPresented: $showingAdd) { AddPlaceView() }
        }
    }
}

private struct SavedPlacesView: View {
    @EnvironmentObject private var places: SavedPlacesStore
    let onExplore: () -> Void
    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Your places, on this iPhone").font(.subheadline.weight(.semibold))
                            Text("Saved coordinates stay available after restarting the app.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "bookmark.circle.fill").font(.title).foregroundStyle(.blue)
                    }
                    .padding(.vertical, 8)
                }
                Section("Saved places") {
                    if places.places.isEmpty {
                        ContentUnavailableView("No saved places", systemImage: "mappin.slash.circle",
                                               description: Text("Add a coordinate to keep it here."))
                    }
                    ForEach(places.places) { place in
                        Button {
                            places.selectedPlace = place
                            onExplore()
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "mappin.and.ellipse")
                                    .font(.title3).foregroundStyle(.blue)
                                    .frame(width: 38, height: 42)
                                    .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(place.name).font(.body.weight(.medium)).foregroundStyle(.primary)
                                    Text(place.coordinateText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }.padding(.vertical, 5)
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { places.remove(place) }
                        }
                    }
                }
                Section {
                    Text("Selecting a place changes the preview in this app. System-wide Mock Location is controlled separately by YIOS-KIT on your Mac.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Saved places")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add Place", systemImage: "plus") { showingAdd = true }
                }
            }
            .sheet(isPresented: $showingAdd) { AddPlaceView() }
        }
    }
}

private struct AddPlaceView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var places: SavedPlacesStore
    @State private var name = ""
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Place") {
                    TextField("Name", text: $name).textInputAutocapitalization(.words)
                        .onChange(of: name) { _, value in if value.count > 100 { name = String(value.prefix(100)) } }
                }
                Section {
                    TextField("Latitude", text: $latitude).keyboardType(.numbersAndPunctuation)
                    TextField("Longitude", text: $longitude).keyboardType(.numbersAndPunctuation)
                } header: { Text("WGS 84 coordinates") }
                  footer: { Text("Latitude: −90 to 90. Longitude: −180 to 180. Use a dot for decimal values.") }
                if let error {
                    Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("addPlaceError") }
                }
                Section {
                    Text("Saving a place does not change the location reported by iOS.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add a place").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if places.add(name: name, latitude: latitude, longitude: longitude) {
                            dismiss()
                        } else {
                            error = places.places.count >= 200
                                ? "You can keep up to 200 saved places. Remove one before adding another."
                                : "Enter a name and valid latitude and longitude."
                        }
                    }.fontWeight(.semibold)
                }
            }
        }
    }
}

private struct CompanionHelpView: View {
    @EnvironmentObject private var location: PhoneLocationReader

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "1.0") (\(info["CFBundleVersion"] as? String ?? "1"))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        CompanionWordmark()
                        Text("Your iPhone companion.")
                            .font(.title2.weight(.bold))
                        Text("Preview and save places on your phone. Install and update this companion from YIOS-KIT on your Mac.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 12)
                }
                Section("Mac connection") {
                    Label("No live Mac session", systemImage: "desktopcomputer")
                    Text("This version is a standalone companion. Automatic installation is handled by the Mac app when a supported, trusted iPhone connects. It does not create a live connection or sync your saved places.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Mock Location") {
#if targetEnvironment(simulator)
                    Label("Test in the Mock Location tab", systemImage: "location.viewfinder")
                    Text("An explicitly configured local Mac bridge can change this simulator's system location. The app verifies the result using a fresh Core Location sample. The simulator test does not enable the same feature on a physical iPhone.")
                        .font(.footnote).foregroundStyle(.secondary)
#else
                    Label("Use YIOS-KIT on your Mac", systemImage: "location.viewfinder")
                    Text("The map in this app is a preview. This version cannot set or resume a system-wide simulated location. Installing the companion does not preserve a Mock Location session through an iPhone restart.")
                        .font(.footnote).foregroundStyle(.secondary)
#endif
                }
                Section("Privacy") {
                    LabeledContent("Location access", value: location.permissionLabel)
                    Text("Coordinates are saved locally on this iPhone. Location access is requested only when you tap Read iPhone Location. The app does not upload coordinates, collect Apple Account credentials, or receive pairing secrets from your Mac. Apple Maps may use the network to load map content.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if location.authorization == .denied {
                        Button("Open iPhone Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                }
                Section("About") {
                    LabeledContent("YIOS-KIT Companion", value: version)
                    LabeledContent("Designed for", value: "Personal use")
                }
            }
            .navigationTitle("Companion")
        }
    }
}

private struct CompanionWordmark: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.title3.weight(.semibold)).foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(LinearGradient(colors: [Color(red: 0.16, green: 0.56, blue: 1), .blue],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 2) {
                Text("YIOS-KIT").font(.headline.weight(.bold))
                Text("COMPANION").font(.system(size: 9, weight: .semibold)).tracking(2).foregroundStyle(.secondary)
            }
        }
    }
}

private extension View {
    func companionCard() -> some View {
        padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 20))
    }
}
