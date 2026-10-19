import AppKit
import SwiftUI

enum Level {
    case low, mid, warn, high

    init(_ pct: Double) {
        switch pct {
        case ..<50: self = .low
        case ..<75: self = .mid
        case ..<90: self = .warn
        default: self = .high
        }
    }

    var nsColor: NSColor {
        switch self {
        case .low: return NSColor(srgbRed: 0.20, green: 0.78, blue: 0.47, alpha: 1)
        case .mid: return NSColor(srgbRed: 0.93, green: 0.74, blue: 0.16, alpha: 1)
        case .warn: return NSColor(srgbRed: 0.98, green: 0.55, blue: 0.18, alpha: 1)
        case .high: return NSColor(srgbRed: 0.96, green: 0.30, blue: 0.30, alpha: 1)
        }
    }

    var color: Color { Color(nsColor: nsColor) }
}

enum Fmt {
    private static let en = Locale(identifier: "en_US_POSIX")

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = en
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let weekdayTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = en
        f.dateFormat = "EEE HH:mm"
        return f
    }()

    static func pct(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    /// "2d 9h", "3h 18m", "48m", "<1m".
    static func countdown(to date: Date, from now: Date) -> String {
        let s = Int(date.timeIntervalSince(now))
        if s < 60 { return "<1m" }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    /// "14:00" today, "Sat 22:59" later.
    static func clock(_ date: Date, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now) ? time.string(from: date) : weekdayTime.string(from: date)
    }

    static func ago(_ date: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }
}
