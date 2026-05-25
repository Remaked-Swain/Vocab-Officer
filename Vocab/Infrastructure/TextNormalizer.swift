import Foundation

enum TextNormalizer {
    static func normalizeEnglish(_ value: String) -> String {
        normalize(value).lowercased()
    }

    static func normalizeKorean(_ value: String) -> String {
        normalize(value)
    }

    private static func normalize(_ value: String) -> String {
        let stripped = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
        return stripped
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

struct SeoulCalendar {
    private static var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }()

    static func day(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    static func daysAgo(_ count: Int, from date: Date) -> Date {
        calendar.date(byAdding: .day, value: -count, to: date) ?? date
    }
}

