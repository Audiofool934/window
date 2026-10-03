import AppKit
import MapKit
import SwiftUI
import WindowCore

enum PlaceLabel {
    /// City-level coordinates, the same rounding the weather uses.
    static func coordinates(_ place: Coordinate) -> String {
        let place = place.cityLevel
        let lat = String(format: "%.1f°%@", abs(place.latitude), place.latitude >= 0 ? "N" : "S")
        let lon = String(format: "%.1f°%@", abs(place.longitude), place.longitude >= 0 ? "E" : "W")
        return "\(lat) \(lon)"
    }
}

/// A map for standing the window somewhere, whether or not the user is there.
struct PlacePickerView: View {
    @State var coordinate: Coordinate
    let usePlace: (Coordinate) -> Void
    let useThisMac: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Where the window stands")
                .font(.headline)
            Text("The sky follows the marker. Pan the map to where you are, or to anywhere you want the room to look out on.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ZStack {
                PlaceMap(coordinate: $coordinate)
                Circle()
                    .strokeBorder(.white, lineWidth: 2)
                    .background(Circle().fill(Color.accentColor))
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .frame(width: 440, height: 300)
            .accessibilityLabel("Map. Pan until the marker sits on the place.")
            Text("The sky uses \(PlaceLabel.coordinates(coordinate)).")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Use This Mac") {
                    useThisMac()
                    close()
                }
                Spacer()
                Button("Use This Place") {
                    usePlace(coordinate)
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

/// The place is the centre of the map. Panning moves it; the marker stays put.
private struct PlaceMap: NSViewRepresentable {
    @Binding var coordinate: Coordinate

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsZoomControls = true
        map.showsCompass = true
        map.setAccessibilityLabel("Map")
        map.region = MKCoordinateRegion(center: coordinate.location, span: MKCoordinateSpan(latitudeDelta: 6, longitudeDelta: 6))
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: PlaceMap

        init(_ parent: PlaceMap) { self.parent = parent }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let center = mapView.centerCoordinate
            let next = Coordinate(latitude: center.latitude, longitude: center.longitude)
            guard abs(next.latitude - parent.coordinate.latitude) > 1e-5
                    || abs(next.longitude - parent.coordinate.longitude) > 1e-5 else { return }
            parent.coordinate = next
        }
    }
}

private extension Coordinate {
    var location: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

enum PlacePickerWindow {
    static func make(coordinate: Coordinate, usePlace: @escaping (Coordinate) -> Void, useThisMac: @escaping () -> Void) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 460), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Place"
        window.isReleasedWhenClosed = false
        let view = PlacePickerView(coordinate: coordinate, usePlace: usePlace, useThisMac: useThisMac, close: { [weak window] in window?.close() })
        window.contentViewController = NSHostingController(rootView: view)
        window.center()
        return window
    }
}
