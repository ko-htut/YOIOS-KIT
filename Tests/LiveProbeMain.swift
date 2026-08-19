import Foundation

@main
struct LiveProbeMain {
    static func main() {
        let snapshot = DeviceDetector.enriched()
        print("mode=\(snapshot.mode.rawValue)")
        print("count=\(snapshot.deviceCount)")
        print("pid=\(snapshot.pidHex)")
        print("product=\(snapshot.productType ?? "—")")
        print("modeVerified=\(snapshot.modeVerified)")
        print("ecid=\(snapshot.ecid == nil ? "—" : "present")")
        print("udid=\(snapshot.udid == nil ? "—" : "present")")
    }
}
