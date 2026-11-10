import Foundation

struct GPSPoint: Codable, Equatable, Identifiable {
    var lat: Double
    var lon: Double
    var t: Double                 // milliseconds since Unix epoch, identical to RUN30 web
    var seg: Int
    var accuracy: Double?
    var id: String { "\(Int(t))-\(seg)" }
}

struct GPSRecord: Codable, Equatable {
    var points: [GPSPoint]
    var startedAt: String?
    var endedAt: String?
    var elapsedSec: Int
    var distanceM: Int
    var rejected: Int
}

struct RunRecord: Codable, Equatable {
    var done: Bool = true
    var distance: Double
    var minutes: Double?
    var rpe: Int = 3
    var pain: Bool = false
    var notes: String = ""
    var updatedAt: String = Date().isoString
    var startedAt: String?
    var gps: GPSRecord?
}

extension Date {
    var isoString: String { ISO8601DateFormatter().string(from: self) }
}

enum TrainingPlan {
    static let distances: [[Double]] = [
        [2,2,2,3], [2,2.5,2,3.5], [2.5,2.5,2,4], [2,2,2,3],
        [3,3,2,4.5], [3,3,3,5], [3.5,3.5,3,6], [3,3,2.5,4.5],
        [4,4,3,6.5], [4,4.5,3.5,7.5], [4.5,5,4,8.5], [4,4,3,6],
        [5,5,4,9.5], [5,5.5,4.5,11], [5.5,6,5,12.5], [4.5,5,4,9],
        [6,6,5,14], [6,7,5,16], [7,7,5,18], [5,6,4,13],
        [7,8,5,20], [8,8,6,22], [8,9,6,24], [6,7,5,16],
        [7,7,5,10], [4,3,2,30]
    ]
    static let dayNames = ["Вторник", "Четверг", "Суббота", "Воскресенье"]
    static let dayShort = ["Вт", "Чт", "Сб", "Вс"]
    static let dayOffsets = [1, 3, 5, 6]
    static let readiness = [
        "Без боли во время тренировок",
        "Разговорный темп сохранялся",
        "Усталость прошла за 24–48 часов",
        "Нет боли в суставах или сухожилиях",
        "Нормальный сон, аппетит и самочувствие"
    ]
    static func key(_ week: Int, _ day: Int) -> String { "\(week)-\(day)" }
    static func activeWeek(startISO: String) -> Int {
        let parts = startISO.split(separator:"-").compactMap { Int($0) }
        guard parts.count == 3,
              let first = Calendar.current.date(from:DateComponents(year:parts[0],month:parts[1],day:parts[2])) else { return 1 }
        let delta = Calendar.current.dateComponents([.day],from:first,to:Date()).day ?? 0
        return min(26,max(1,delta / 7 + 1))
    }
    static func planned(_ week: Int, _ day: Int) -> Double {
        guard (1...26).contains(week), (0...3).contains(day) else { return 0 }
        return distances[week - 1][day]
    }
    static func date(startISO: String, week: Int, day: Int) -> Date? {
        let items = startISO.split(separator: "-").compactMap { Int($0) }
        guard items.count == 3, (0...3).contains(day) else { return nil }
        let c = DateComponents(year: items[0], month: items[1], day: items[2], hour: 12)
        guard let start = Calendar.current.date(from: c) else { return nil }
        return Calendar.current.date(byAdding: .day, value: (week - 1) * 7 + dayOffsets[day], to: start)
    }
    static var nextMondayISO: String {
        let cal = Calendar.current
        let today = Date()
        let weekday = (cal.component(.weekday, from: today) + 5) % 7  // Mon=0
        let delta = weekday == 0 ? 0 : 7 - weekday
        let monday = cal.date(byAdding: .day, value: delta, to: today) ?? today
        return dateISO(monday)
    }
    static func dateISO(_ date: Date) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.locale = Locale(identifier: "en_US_POSIX")
        return df.string(from: date)
    }
    static func display(_ date: Date?) -> String {
        guard let date else { return "—" }
        let df = DateFormatter(); df.locale = Locale(identifier: "ru_RU"); df.dateFormat = "d MMM"
        return df.string(from: date)
    }
}

// Type-safe envelope for Supabase JSONB (same {data,deleted} structure as web RUN30).
indirect enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    static func wrap<T: Encodable>(_ x: T) throws -> JSONValue {
        let raw = try JSONEncoder().encode(x)
        return try JSONDecoder().decode(JSONValue.self, from: raw)
    }
    func unwrap<T: Decodable>(_ t: T.Type) -> T? {
        guard let raw = try? JSONEncoder().encode(self) else { return nil }
        return try? JSONDecoder().decode(t, from: raw)
    }
}
