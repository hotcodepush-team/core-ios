import Foundation

/// One JSON convention for every wire shape: ISO 8601 timestamps with fractional seconds tolerated.
public enum Json {
    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            guard let date = Iso8601.parse(value) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not an ISO 8601 timestamp: \(value)"))
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

public enum Iso8601 {
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

    public static func parse(_ value: String) -> Date? {
        return withFractionalSeconds.date(from: value) ?? withoutFractionalSeconds.date(from: value)
    }
}
