import Foundation

/// A calendar day — the operand of the web app's `date:` search operator
/// ("2025-12-01"). Not a server narrow term: a date search fetches its
/// other terms' narrow anchored at the day's local midnight
/// (`MessageAnchor.date`), so it lands among that day's messages without
/// filtering to them. ISO days are Gregorian whatever the user's calendar.
public struct CalendarDay: Sendable, Hashable, Comparable, Codable {
    public let year: Int
    public let month: Int
    public let day: Int

    /// A real day (no February 30th) with a four-digit year.
    public init?(year: Int, month: Int, day: Int) {
        guard (1...9999).contains(year), (1...12).contains(month), day >= 1 else { return nil }
        let calendar = Self.gregorian(.gmt)
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.day, from: date) == day
        else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Strict `YYYY-MM-DD`, as the web reads the operand: unpadded forms
    /// ("2026-1-1") are refused.
    public init?(iso: String) {
        let parts = iso.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        self.init(year: year, month: month, day: day)
    }

    /// The day `date` falls on in `timeZone`.
    public init(_ date: Date, timeZone: TimeZone = .current) {
        let parts = Self.gregorian(timeZone).dateComponents([.year, .month, .day], from: date)
        year = parts.year ?? 1970
        month = parts.month ?? 1
        day = parts.day ?? 1
    }

    public var iso: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// The local midnight that starts the day — the instant a date search
    /// anchors at. (Via noon: a zone that skips midnight still yields the
    /// day's first moment.)
    public func start(in timeZone: TimeZone = .current) -> Date {
        let calendar = Self.gregorian(timeZone)
        let noon = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
        return calendar.startOfDay(for: noon ?? .distantPast)
    }

    /// Searchable, as the web bounds it: from 1970 (nothing older carries
    /// a timestamp) through the end of the current year.
    public func isSearchable(now: Date = .now, timeZone: TimeZone = .current) -> Bool {
        (1970...CalendarDay(now, timeZone: timeZone).year).contains(year)
    }

    public static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let iso = try container.decode(String.self)
        guard let day = CalendarDay(iso: iso) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Not a YYYY-MM-DD day: \(iso)")
        }
        self = day
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(iso)
    }

    private static func gregorian(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}

// MARK: Search typeahead (after the web's date_util.ts)

extension CalendarDay {
    /// The web's quick picks, nearest first, with the names its search
    /// pills show (two days ago has none: it shows as the date).
    private static func quickPicks(
        now: Date, timeZone: TimeZone
    ) -> [(day: CalendarDay, name: String?)] {
        let calendar = gregorian(timeZone)
        func back(_ component: Calendar.Component, _ value: Int) -> CalendarDay {
            CalendarDay(
                calendar.date(byAdding: component, value: -value, to: now) ?? now,
                timeZone: timeZone)
        }
        return [
            (CalendarDay(now, timeZone: timeZone), "today"),
            (back(.day, 1), "yesterday"),
            (back(.day, 2), nil),
            (back(.day, 7), "a week ago"),
            (back(.month, 1), "a month ago"),
        ]
    }

    /// The name a search bubble shows for a quick-pick day ("today",
    /// "a week ago"); nil for any other day, which shows as a date.
    public func relativeName(now: Date = .now, timeZone: TimeZone = .current) -> String? {
        Self.quickPicks(now: now, timeZone: timeZone).first { $0.day == self }?.name
    }

    /// Days to suggest for typed search text, as the web suggests `date:`
    /// operands: a quick-pick name by word prefix ("yes", "week"), or a
    /// half-typed `YYYY-MM-DD` completed toward each quick pick in turn.
    /// A leading "date:" is the web's operator, typed out; without it a
    /// name needs three characters and digits need a dash — a bare
    /// number is more likely text to search for than a date in progress.
    public static func suggestions(
        for text: String, now: Date = .now, timeZone: TimeZone = .current
    ) -> [CalendarDay] {
        var operand = text.trimmingCharacters(in: .whitespaces).lowercased()
        let typedOperator = operand.hasPrefix("date:")
        if typedOperator {
            operand = operand.dropFirst("date:".count).trimmingCharacters(in: .whitespaces)
        }
        let picks = quickPicks(now: now, timeZone: timeZone)
        guard !operand.isEmpty else { return typedOperator ? picks.map(\.day) : [] }
        var days: [CalendarDay] = []
        if operand.allSatisfy({ $0 == "-" || ($0.isASCII && $0.isNumber) }) {
            guard typedOperator || operand.contains("-") else { return [] }
            for pick in picks {
                if let day = completion(of: operand, toward: pick.day),
                   day.isSearchable(now: now, timeZone: timeZone), !days.contains(day) {
                    days.append(day)
                }
            }
        } else {
            guard typedOperator || operand.count >= 3 else { return [] }
            for pick in picks {
                if let name = pick.name, (" " + name).contains(" " + operand) {
                    days.append(pick.day)
                }
            }
        }
        return days
    }

    /// Completes a half-typed `YYYY-MM-DD` the way the web does: a part
    /// still on course for `target` takes the target's value; once one
    /// diverges, a missing part defaults to 01 and a short one pads with
    /// zeros ("2025-1" is "2025-10" on its way).
    static func completion(of operand: String, toward target: CalendarDay) -> CalendarDay? {
        var cleaned = Substring(operand)
        while cleaned.hasSuffix("-") { cleaned = cleaned.dropLast() }
        guard !cleaned.isEmpty else { return nil }
        var typed = cleaned.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard typed.count <= 3 else { return nil }
        typed += Array(repeating: "", count: 3 - typed.count)
        let targets = [
            String(format: "%04d", target.year),
            String(format: "%02d", target.month),
            String(format: "%02d", target.day),
        ]
        var onCourse = true
        var values: [Int] = []
        for (index, (part, targetPart)) in zip(typed, targets).enumerated() {
            let width = index == 0 ? 4 : 2
            guard part.count <= width else { return nil }
            let segment: String
            if part.isEmpty {
                segment = index == 0 || onCourse ? targetPart : "01"
            } else if onCourse, targetPart.hasPrefix(part) {
                segment = targetPart
            } else {
                onCourse = false
                // A lone "0" can't pad to a month or day ("00").
                segment = index > 0 && part == "0"
                    ? "01" : part.padding(toLength: width, withPad: "0", startingAt: 0)
            }
            guard let value = Int(segment) else { return nil }
            values.append(value)
        }
        return CalendarDay(year: values[0], month: values[1], day: values[2])
    }
}
