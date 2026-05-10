import Foundation

enum Fmt {
    nonisolated(unsafe) static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return isoFractional.date(from: s) ?? iso.date(from: s)
    }

    static func currency(_ cents: Int?, code: String = "USD") -> String {
        let value = Double(cents ?? 0) / 100.0
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = code
        return f.string(from: NSNumber(value: value)) ?? "$0.00"
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    static func short(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    static func dateTime(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Combines `booking_date` + `start_time` ("HH:mm:ss" or "HH:mm") into a friendly label.
    static func bookingWhen(_ b: AmenityBooking) -> String {
        let date = parseDate(b.booking_date) ?? parseDay(b.booking_date)
        let dateStr = short(date)
        if let t = b.start_time, !t.isEmpty {
            return "\(dateStr) · \(formatTime(t))"
        }
        return dateStr
    }

    static func parseDay(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }

    static func formatTime(_ s: String) -> String {
        let parts = s.split(separator: ":")
        guard parts.count >= 2,
              let h = Int(parts[0]), let m = Int(parts[1]) else { return s }
        var comps = DateComponents()
        comps.hour = h; comps.minute = m
        if let d = Calendar.current.date(from: comps) {
            return d.formatted(date: .omitted, time: .shortened)
        }
        return s
    }
}
