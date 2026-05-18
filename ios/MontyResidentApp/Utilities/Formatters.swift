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

    nonisolated(unsafe) private static let currencyFormatters: NSCache<NSString, NumberFormatter> = {
        let c = NSCache<NSString, NumberFormatter>()
        c.countLimit = 8
        return c
    }()

    static func currencyFormatter(code: String = "USD", maxFractionDigits: Int = 2) -> NumberFormatter {
        let key = "\(code)-\(maxFractionDigits)" as NSString
        if let cached = currencyFormatters.object(forKey: key) { return cached }
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = code
        f.maximumFractionDigits = maxFractionDigits
        currencyFormatters.setObject(f, forKey: key)
        return f
    }

    static func currency(_ cents: Int?, code: String = "USD") -> String {
        let value = Double(cents ?? 0) / 100.0
        return currencyFormatter(code: code).string(from: NSNumber(value: value)) ?? "$0.00"
    }

    /// Whole-dollar currency string (no fractional digits). Used on Home tiles.
    static func currencyWhole(cents: Int, code: String = "USD") -> String {
        let value = Double(cents) / 100.0
        return currencyFormatter(code: code, maxFractionDigits: 0).string(from: NSNumber(value: value)) ?? "—"
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

    nonisolated(unsafe) private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func parseDay(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return dayFormatter.date(from: s)
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
