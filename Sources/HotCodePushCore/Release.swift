import Foundation

/// The SDK's own view of an index entry: what is on disk, what runs, what passed the gate.
public struct Release: Codable, Equatable {
    public let id: String
    public let number: Int
    public let bundleId: String
    public let bundleVersion: String
    public let isMandatory: Bool

    enum CodingKeys: String, CodingKey {
        case id, number, bundleId, bundleVersion, isMandatory
    }

    public init(id: String, number: Int, bundleId: String, bundleVersion: String, isMandatory: Bool) {
        self.id = id
        self.number = number
        self.bundleId = bundleId
        self.bundleVersion = bundleVersion
        self.isMandatory = isMandatory
    }

    /// A stored release's ids are identifiers, so neither names another path; one that is not drops the cache like any unreadable value.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(.identifier, forKey: .id)
        number = try container.decode(Int.self, forKey: .number)
        bundleId = try container.decode(.identifier, forKey: .bundleId)
        bundleVersion = try container.decode(String.self, forKey: .bundleVersion)
        isMandatory = try container.decode(Bool.self, forKey: .isMandatory)
    }
}
