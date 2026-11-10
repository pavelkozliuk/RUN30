import Foundation
import CoreLocation
import Combine

struct TrackSession: Codable {
    enum Mode: String, Codable { case idle, running, paused, finished }
    var mode: Mode = .idle
    var week: Int = 1
    var day: Int = 0
    var startedAt: String? = nil
    var endedAt: String? = nil
    var activeSeconds: Double = 0
    var totalMeters: Double = 0
    var points: [GPSPoint] = []
    var segment: Int = 0
    var rejected: Int = 0
    var info: String = "Ожидаем начало тренировки"
    var accuracy: Double? = nil
}

final class GPSTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var session = TrackSession()
    @Published private(set) var seconds: Double = 0
    @Published private(set) var permission = "Не запрошено"

    private let manager = CLLocationManager()
    private var runAnchor: Date?
    private let storageURL: URL

    override init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        storageURL = root.appendingPathComponent("run30-gps-draft.json")
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
        loadDraft()
        updatePermission()
    }

    var active: Bool { session.mode == .running }
    var hasDraft: Bool { session.mode != .idle }
    var distanceKm: Double { session.totalMeters / 1000 }
    var paceSecondsPerKm: Double? {
        guard distanceKm >= 0.02, seconds > 0 else { return nil }
        return seconds / distanceKm
    }

    func start(week: Int, day: Int) {
        guard (1...26).contains(week), (0...3).contains(day), session.mode == .idle else { return }
        session = TrackSession(mode: .running, week: week, day: day,
                               startedAt: Date().isoString, info: "Ожидание сигнала GPS…")
        runAnchor = Date()
        seconds = 0
        saveDraft()
        beginGPS()
    }

    func pause() {
        guard session.mode == .running else { return }
        session.activeSeconds = elapsed()
        session.mode = .paused
        session.info = "Пауза: GPS не записывается"
        runAnchor = nil
        seconds = session.activeSeconds
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        saveDraft()
    }

    func resume() {
        guard session.mode == .paused else { return }
        session.segment += 1 // prevents a straight-line jump across the pause
        session.mode = .running
        session.info = "Возобновление GPS…"
        runAnchor = Date()
        saveDraft()
        beginGPS()
    }

    func finish() {
        guard session.mode == .running || session.mode == .paused else { return }
        if session.mode == .running { session.activeSeconds = elapsed() }
        session.mode = .finished
        session.endedAt = Date().isoString
        runAnchor = nil
        seconds = session.activeSeconds
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        saveDraft()
    }

    func discard() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        runAnchor = nil
        session = TrackSession()
        seconds = 0
        try? FileManager.default.removeItem(at: storageURL)
    }

    func pulse() {
        let elapsedNow = elapsed()
        if abs(seconds - elapsedNow) >= 0.3 { seconds = elapsedNow }
    }

    func makeRecord(rpe: Int, pain: Bool, notes: String) -> RunRecord {
        let total = max(0, elapsed())
        let gps = GPSRecord(points: session.points, startedAt: session.startedAt,
                            endedAt: session.endedAt, elapsedSec: Int(total.rounded()),
                            distanceM: Int(session.totalMeters.rounded()), rejected: session.rejected)
        return RunRecord(distance: (session.totalMeters / 10).rounded() / 100,
                         minutes: (total / 60 * 100).rounded() / 100,
                         rpe: rpe, pain: pain, notes: String(notes.prefix(1500)),
                         updatedAt: Date().isoString, startedAt: session.startedAt, gps: gps)
    }

    private func elapsed() -> Double {
        session.activeSeconds + (runAnchor.map { max(0, Date().timeIntervalSince($0)) } ?? 0)
    }

    private func beginGPS() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.allowsBackgroundLocationUpdates = true // UIBackgroundModes=location in Info.plist
            manager.startUpdatingLocation()
        case .denied, .restricted:
            session.info = "Разреши геолокацию для RUN30 в Настройках iPhone"
            saveDraft()
        @unknown default:
            session.info = "Неизвестный статус доступа к GPS"
        }
        updatePermission()
    }

    private func updatePermission() {
        switch manager.authorizationStatus {
        case .authorizedAlways: permission = "Всегда"
        case .authorizedWhenInUse: permission = "Во время использования"
        case .notDetermined: permission = "Разрешение не запрошено"
        case .denied: permission = "Доступ запрещён"
        case .restricted: permission = "Доступ ограничен"
        @unknown default: permission = "Неизвестно"
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        updatePermission()
        if session.mode == .running { beginGPS() }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        session.info = "GPS: \(error.localizedDescription)"
        saveDraft()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard session.mode == .running else { return }
        for loc in locations.sorted(by: { $0.timestamp < $1.timestamp }) { accept(loc) }
    }

    private func accept(_ loc: CLLocation) {
        let accuracy = loc.horizontalAccuracy
        let age = abs(Date().timeIntervalSince(loc.timestamp))
        guard loc.coordinate.latitude.isFinite, loc.coordinate.longitude.isFinite,
              accuracy >= 0, accuracy <= 50, age <= 20 else {
            session.rejected += 1
            session.info = "Ожидание точного GPS (погрешность до 50 м)"
            return
        }
        let point = GPSPoint(lat: (loc.coordinate.latitude * 1_000_000).rounded() / 1_000_000,
                             lon: (loc.coordinate.longitude * 1_000_000).rounded() / 1_000_000,
                             t: loc.timestamp.timeIntervalSince1970 * 1000,
                             seg: session.segment, accuracy: accuracy.rounded())
        var candidate = point
        session.accuracy = accuracy
        if let prev = session.points.last, prev.seg == point.seg {
            let dt = (point.t - prev.t) / 1000
            if dt <= 0 { return }
            let old = CLLocation(latitude: prev.lat, longitude: prev.lon)
            let distance = old.distance(from: loc)
            if dt > 45 {
                session.segment += 1
                candidate.seg = session.segment
            } else if distance < max(6, accuracy * 0.25) || dt < 1.5 {
                return
            } else if distance / dt > 7 {
                session.rejected += 1
                session.info = "Резкий GPS-скачок отклонён"
                return
            } else {
                session.totalMeters += distance
            }
        }
        guard session.points.count < 5000 else {
            session.info = "Достигнут предел 5000 точек. Заверши тренировку."
            manager.stopUpdatingLocation()
            return
        }
        session.points.append(candidate)
        session.info = "GPS работает · точность ±\(Int(accuracy)) м"
        seconds = elapsed()
        saveDraft() // includes current elapsed time; resume after crash is paused
    }

    private func saveDraft() {
        var snapshot = session
        if snapshot.mode == .running { snapshot.activeSeconds = elapsed() }
        guard let bytes = try? JSONEncoder().encode(snapshot) else { return }
        try? bytes.write(to: storageURL, options: .atomic)
    }

    private func loadDraft() {
        guard let bytes = try? Data(contentsOf: storageURL),
              var restored = try? JSONDecoder().decode(TrackSession.self, from: bytes) else { return }
        if restored.mode == .running {
            restored.mode = .paused
            restored.segment += 1
            restored.info = "После перезапуска запись приостановлена. Проверь маршрут и продолжи."
        }
        session = restored
        seconds = restored.activeSeconds
    }
}
