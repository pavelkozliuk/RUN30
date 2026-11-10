import SwiftUI
import MapKit

struct RouteMap: UIViewRepresentable {
    var points: [GPSPoint]
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.mapType = .standard
        map.showsCompass = true
        return map
    }
    func updateUIView(_ map: MKMapView, context: Context) {
        let latest = points.last?.t ?? -1
        guard points.count != context.coordinator.lastPointCount || latest != context.coordinator.lastPointTime else { return }
        context.coordinator.lastPointCount = points.count
        context.coordinator.lastPointTime = latest
        map.removeOverlays(map.overlays)
        let grouped = Dictionary(grouping: points, by: { $0.seg })
        for seg in grouped.keys.sorted() {
            let group = (grouped[seg] ?? []).sorted(by: { $0.t < $1.t })
            guard group.count > 1 else { continue }
            let coords = group.map { CLLocationCoordinate2D(latitude:$0.lat,longitude:$0.lon) }
            map.addOverlay(MKPolyline(coordinates:coords,count:coords.count))
        }
        if let first = points.first {
            if points.count == 1 {
                map.setRegion(MKCoordinateRegion(center:CLLocationCoordinate2D(latitude:first.lat, longitude:first.lon),
                                                latitudinalMeters:700, longitudinalMeters:700), animated:false)
            } else if !map.overlays.isEmpty {
                var rect = MKMapRect.null
                for overlay in map.overlays { rect = rect.union(overlay.boundingMapRect) }
                if !rect.isNull { map.setVisibleMapRect(rect, edgePadding:UIEdgeInsets(top:30,left:30,bottom:30,right:30), animated:false) }
            }
        }
    }
    final class Coordinator: NSObject, MKMapViewDelegate {
        var lastPointCount = -1
        var lastPointTime: Double = -1
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay:overlay) }
            let render = MKPolylineRenderer(polyline:line)
            render.strokeColor = UIColor.systemGreen
            render.lineWidth = 5
            return render
        }
    }
}

struct RouteDetails: View {
    let record: RunRecord
    @State private var gpxURL: URL?

    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                if let gps = record.gps, !gps.points.isEmpty {
                    RouteMap(points:gps.points)
                        .frame(height:390)
                        .clipShape(RoundedRectangle(cornerRadius:16))
                    HStack {
                        metric("Дистанция",String(format:"%.2f км",record.distance))
                        metric("Время",String(format:"%.1f мин",record.minutes ?? 0))
                        metric("GPS-точек","\(gps.points.count)")
                    }
                    if let url = gpxURL {
                        ShareLink(item:url) { Label("Поделиться маршрутом GPX", systemImage:"square.and.arrow.up") }
                            .buttonStyle(.borderedProminent)
                    }
                    Text("GPX раскрывает точные координаты маршрута, включая место старта и финиша.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else { Label("GPS-маршрут отсутствует", systemImage:"map").foregroundStyle(.secondary) }
            }.padding()
        }
        .navigationTitle("Маршрут")
        .onAppear {
            if let gps = record.gps { gpxURL = GPXExporter.createFile(points:gps.points) }
        }
    }
    private func metric(_ title:String,_ value:String)->some View {
        VStack(alignment:.leading){ Text(value).bold(); Text(title).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth:.infinity)
    }
}

enum GPXExporter {
    static func createFile(points:[GPSPoint]) -> URL? {
        guard !points.isEmpty else { return nil }
        let esc = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        var xml = esc + "<gpx version=\"1.1\" creator=\"RUN30\" xmlns=\"http://www.topografix.com/GPX/1/1\"><trk><name>RUN30</name><trkseg>"
        var lastSeg = points[0].seg
        let df = ISO8601DateFormatter()
        for p in points {
            if p.seg != lastSeg { xml += "</trkseg><trkseg>"; lastSeg = p.seg }
            let stamp = df.string(from: Date(timeIntervalSince1970:p.t / 1000))
            xml += "<trkpt lat=\"\(p.lat)\" lon=\"\(p.lon)\"><time>\(stamp)</time></trkpt>"
        }
        xml += "</trkseg></trk></gpx>"
        let name = "RUN30-\(Int(Date().timeIntervalSince1970)).gpx"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do { try xml.write(to:file,atomically:true,encoding:.utf8); return file } catch { return nil }
    }
}
