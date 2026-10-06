import Foundation

/// The SDK's own view of an index entry: what is on disk, what runs, what passed the gate.
public struct Release: Codable, Equatable {
    public let id: String
    public let number: Int
    public let bundleId: String
    public let bundleVersion: String
    public let isMandatory: Bool

    public init(id: String, number: Int, bundleId: String, bundleVersion: String, isMandatory: Bool) {
        self.id = id
        self.number = number
        self.bundleId = bundleId
        self.bundleVersion = bundleVersion
        self.isMandatory = isMandatory
    }
}
