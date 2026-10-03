import CryptoKit
import Foundation

/// The signature schemes this core verifies: a pinned allow-list the value's prefix selects within and never extends.
/// Ed25519 is the platform's default; `rsa-v1_5-sha256` belongs to the Expo bridge, whose clients verify the Expo-format
/// manifest themselves, so a key or a signature of that scheme verifies nothing here.
public enum SigningScheme: String, CaseIterable {
    case ed25519
}

/// A self-describing value as keys and signatures travel, `<scheme>:<base64>`; the base64 is canonical, so one value has exactly one spelling.
public struct SelfDescribingBytes: Equatable {
    public let scheme: SigningScheme
    public let bytes: Data

    public static func parse(_ value: String) -> SelfDescribingBytes? {
        guard let separator = value.firstIndex(of: ":"), let scheme = SigningScheme(rawValue: String(value[..<separator])) else { return nil }
        let base64 = String(value[value.index(after: separator)...])
        guard let bytes = Data(base64Encoded: base64), bytes.base64EncodedString() == base64 else { return nil }
        return SelfDescribingBytes(scheme: scheme, bytes: bytes)
    }
}

public enum SigningKeys {
    private static let ed25519PublicKeyLength = 32

    /// A public key the verifier can select: a scheme of the allow-list and well-formed key bytes.
    public static func parsePublicKey(_ value: String) -> SelfDescribingBytes? {
        guard let key = SelfDescribingBytes.parse(value) else { return nil }
        switch key.scheme {
        case .ed25519: return key.bytes.count == ed25519PublicKeyLength ? key : nil
        }
    }

    /// `sha256:` and the SHA-256 of the key bytes in hex — a signature's `keyId`, which selects the key it is verified with.
    public static func fingerprint(of key: SelfDescribingBytes) -> String {
        return "sha256:\(Hashing.sha256Hex(key.bytes))"
    }
}

public enum Signatures {
    /// Whether the envelope's signature covers its `manifest` bytes — the string as received, never re-serialized — under the key
    /// its `keyId` names among `publicKeys`; an unsigned envelope verifies against no key.
    public static func verifyManifestSignature(_ envelope: ManifestEnvelope, publicKeys: [String]) -> Bool {
        guard let signature = envelope.signature else { return false }
        return verify(Data(envelope.manifest.utf8), signature: signature, publicKeys: publicKeys)
    }

    static func verify(_ message: Data, signature: Signature, publicKeys: [String]) -> Bool {
        guard let value = SelfDescribingBytes.parse(signature.value),
              let key = resolvePublicKey(named: signature.keyId, among: publicKeys),
              key.scheme == value.scheme else { return false }
        switch key.scheme {
        case .ed25519:
            guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key.bytes) else { return false }
            return publicKey.isValidSignature(value.bytes, for: message)
        }
    }

    private static func resolvePublicKey(named keyId: String, among publicKeys: [String]) -> SelfDescribingBytes? {
        return publicKeys.lazy.compactMap(SigningKeys.parsePublicKey).first { SigningKeys.fingerprint(of: $0) == keyId }
    }
}
