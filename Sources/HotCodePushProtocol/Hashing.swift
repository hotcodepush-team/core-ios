import CryptoKit
import Foundation

public enum Hashing {
    public static func sha256Hex(_ data: Data) -> String {
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(_ string: String) -> String {
        return sha256Hex(Data(string.utf8))
    }

    /// `sha256(key + '\0' + value)`, the form an attribute condition carries.
    public static func attributeHash(key: String, value: String) -> String {
        return sha256Hex(key + "\u{0}" + value)
    }

    /// The hash a `device` condition lists for one device id.
    public static func deviceIdHash(_ deviceId: String) -> String {
        return sha256Hex(deviceId)
    }

    /// The rollout bucket: FNV-1a 32-bit over the UTF-8 bytes of the device id followed by the release id, modulo 100.
    public static func rolloutBucket(deviceId: String, releaseId: String) -> Int {
        var hash: UInt32 = 0x811c9dc5
        for byte in (deviceId + releaseId).utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x01000193
        }
        return Int(hash % 100)
    }
}
