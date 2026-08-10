import Foundation

/// Parses imported metadata dates and normalizes partial dates to a sortable day.
/// Years and months use their first day; ISO week values use Monday.
enum MetadataDateParser {
    nonisolated static func parse(_ rawValue: String, hint: String = "") -> Date? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if let timestamp = isoTimestamp(value) { return timestamp }
        if let week = weekDate(value, hint: hint) { return week }
        if let year = captures(#"^(\d{4})$"#, in: value).flatMap({ Int($0[0]) }) {
            return date(year: year, month: 1, day: 1)
        }
        if isYearHint(hint), let rawYear = captures(#"^(\d{2})$"#, in: value).flatMap({ Int($0[0]) }) {
            return date(year: expandedYear(rawYear, digits: 2), month: 1, day: 1)
        }
        if let parts = captures(#"^(\d{4})[-/.](\d{1,2})$"#, in: value),
           let year = Int(parts[0]), let month = Int(parts[1]) {
            return date(year: year, month: month, day: 1)
        }
        if let ordinal = ordinalDate(value) { return ordinal }
        if let numeric = numericDate(value) { return numeric }
        return formattedDate(value)
    }

    nonisolated private static func isoTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }

    nonisolated private static func weekDate(_ value: String, hint: String) -> Date? {
        let yearFirst = #"(?i)^(\d{4})\s*[-/._ ]?\s*(?:W|WK|CW|KW|WEEK|WOCHE)\s*[-/._ ]?\s*(\d{1,2})$"#
        if let parts = captures(yearFirst, in: value), let year = Int(parts[0]), let week = Int(parts[1]) {
            return isoWeekDate(year: year, week: week)
        }

        let weekFirst = #"(?i)^(?:W|WK|CW|KW|WEEK|WOCHE)\s*[-/._ ]?\s*(\d{1,2})(?:\s*(?:OF|IN|[-/._, ])+\s*(\d{4}))?$"#
        if let parts = captures(weekFirst, in: value), let week = Int(parts[0]) {
            let year = parts.count > 1 && !parts[1].isEmpty ? Int(parts[1]) : currentISOYear()
            return year.flatMap { isoWeekDate(year: $0, week: week) }
        }

        guard isWeekHint(hint) else { return nil }
        if let parts = captures(#"^(\d{1,2})\s*[-/.]\s*(\d{4})$"#, in: value),
           let week = Int(parts[0]), let year = Int(parts[1]) {
            return isoWeekDate(year: year, week: week)
        }
        if let parts = captures(#"^(\d{4})\s*[-/.]\s*(\d{1,2})$"#, in: value),
           let year = Int(parts[0]), let week = Int(parts[1]) {
            return isoWeekDate(year: year, week: week)
        }
        if let week = Int(value), (1...53).contains(week) {
            return isoWeekDate(year: currentISOYear(), week: week)
        }
        return nil
    }

    nonisolated private static func ordinalDate(_ value: String) -> Date? {
        guard let parts = captures(#"^(\d{4})-?(\d{3})$"#, in: value),
              let year = Int(parts[0]), let day = Int(parts[1]), (1...366).contains(day),
              let firstDay = date(year: year, month: 1, day: 1) else { return nil }
        let calendar = gregorianCalendar()
        guard let result = calendar.date(byAdding: .day, value: day - 1, to: firstDay),
              calendar.component(.year, from: result) == year else { return nil }
        return result
    }

    nonisolated private static func numericDate(_ value: String) -> Date? {
        guard let parts = captures(#"^(\d{1,4})([-/.])(\d{1,2})\2(\d{1,4})$"#, in: value),
              let first = Int(parts[0]), let second = Int(parts[2]), let third = Int(parts[3]) else { return nil }

        if parts[0].count == 4 {
            return date(year: first, month: second, day: third)
        }
        guard parts[3].count == 2 || parts[3].count == 4 else { return nil }
        let year = expandedYear(third, digits: parts[3].count)
        if first > 12 { return date(year: year, month: second, day: first) }
        if second > 12 { return date(year: year, month: first, day: second) }
        if localePrefersMonthFirst() {
            return date(year: year, month: first, day: second)
        }
        return date(year: year, month: second, day: first)
    }

    nonisolated private static func formattedDate(_ value: String) -> Date? {
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm",
            "d MMM yyyy", "d MMMM yyyy", "MMM d, yyyy", "MMMM d, yyyy",
            "d. MMM yyyy", "d. MMMM yyyy"
        ]
        let locales = [Locale.current, Locale(identifier: "en_US_POSIX"), Locale(identifier: "de_DE")]
        for locale in locales {
            for format in formats {
                let formatter = DateFormatter()
                formatter.calendar = gregorianCalendar()
                formatter.locale = locale
                formatter.timeZone = .current
                formatter.isLenient = false
                formatter.dateFormat = format
                if let date = formatter.date(from: value) { return date }
            }
        }
        return nil
    }

    nonisolated private static func date(year: Int, month: Int, day: Int) -> Date? {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        let calendar = gregorianCalendar()
        guard let result = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let components = calendar.dateComponents([.year, .month, .day], from: result)
        guard components.year == year, components.month == month, components.day == day else { return nil }
        return result
    }

    nonisolated private static func isoWeekDate(year: Int, week: Int) -> Date? {
        guard (1...9999).contains(year), (1...53).contains(week) else { return nil }
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        guard let result = calendar.date(from: DateComponents(weekday: 2, weekOfYear: week, yearForWeekOfYear: year)) else { return nil }
        let components = calendar.dateComponents([.weekOfYear, .yearForWeekOfYear], from: result)
        guard components.weekOfYear == week, components.yearForWeekOfYear == year else { return nil }
        return result
    }

    nonisolated private static func currentISOYear() -> Int {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        return calendar.component(.yearForWeekOfYear, from: .now)
    }

    nonisolated private static func expandedYear(_ year: Int, digits: Int) -> Int {
        guard digits == 2 else { return year }
        return year <= 69 ? 2000 + year : 1900 + year
    }

    nonisolated private static func localePrefersMonthFirst() -> Bool {
        guard let format = DateFormatter.dateFormat(fromTemplate: "yMd", options: 0, locale: .current),
              let month = format.firstIndex(of: "M"), let day = format.firstIndex(of: "d") else { return false }
        return month < day
    }

    nonisolated private static func isWeekHint(_ hint: String) -> Bool {
        let normalized = normalizedHint(hint)
        return normalized.contains("week") || normalized.contains("woche") || normalized == "kw" || normalized.contains("calendarweek") || normalized == "cw"
    }

    nonisolated private static func isYearHint(_ hint: String) -> Bool {
        let normalized = normalizedHint(hint)
        return normalized.contains("year") || normalized.contains("jahr")
    }

    nonisolated private static func normalizedHint(_ hint: String) -> String {
        hint.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: #"[^a-z0-9]"#, with: "", options: .regularExpression)
    }

    nonisolated private static func gregorianCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    nonisolated private static func captures(_ pattern: String, in value: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.range == NSRange(value.startIndex..., in: value) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            guard match.range(at: index).location != NSNotFound, let range = Range(match.range(at: index), in: value) else { return "" }
            return String(value[range])
        }
    }
}
