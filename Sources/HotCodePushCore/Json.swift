import Foundation

/// One JSON convention for every wire shape: ISO 8601 timestamps in UTC, written with milliseconds, read with any fraction and never with an offset.
public enum Json {
    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            guard let date = Iso8601.parse(value) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not an ISO 8601 timestamp in UTC: \(value)"))
            }
            return date
        }
        return decoder
    }()

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Iso8601.format(date))
        }
        return encoder
    }()
}

/// Timestamps travel as `2026-09-29T10:00:00.000Z`: UTC with a `Z`, the fraction read to the millisecond whatever its length, an offset refused.
public enum Iso8601 {
    private static let pattern = try! NSRegularExpression(pattern: "^(\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2})(?:\\.(\\d{1,9}))?Z$")

    private static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let withoutFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public static func format(_ date: Date) -> String {
        return withFractionalSeconds.string(from: date)
    }

    /// The timestamp's month in UTC, `2026-09`, which orders as the months do.
    public static func resolveUtcMonth(of date: Date) -> String {
        return String(format(date).prefix(7))
    }

    public static func parse(_ value: String) -> Date? {
        let range = NSRange(value.startIndex..., in: value)
        guard let match = pattern.firstMatch(in: value, range: range), let secondsRange = Range(match.range(at: 1), in: value) else { return nil }
        guard let seconds = withoutFractionalSeconds.date(from: "\(value[secondsRange])Z") else { return nil }
        guard let fractionRange = Range(match.range(at: 2), in: value) else { return seconds }
        let milliseconds = Double(String(value[fractionRange]).padding(toLength: 3, withPad: "0", startingAt: 0)) ?? 0
        return seconds.addingTimeInterval(milliseconds / 1000)
    }
}
