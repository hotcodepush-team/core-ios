import Foundation
import Security

/// A public key from the resource file: the base64 of its PKCS #1 DER and its key id.
/// The key id is the fingerprint a signature names, which a device cannot recompute from the key bytes.
public struct DevicePublicKey: Codable, Equatable {
    public let der: String
    public let keyId: String

    init(der: String, keyId: String) {
        self.der = der
        self.keyId = keyId
    }

    /// Refuses a `der` that is not canonical base64 and an empty `keyId`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        der = try container.decode(.base64, forKey: .der)
        keyId = try container.decode(.nonEmpty, forKey: .keyId)
    }
}

/// Why a manifest's signature was refused, one case per cause.
public enum SignatureRefusal: Error, Equatable {
    /// The envelope carries no signature.
    case unsigned
    /// The signature names a scheme other than `rsa-v1_5-sha256`, `ed25519` included.
    case unknownScheme
    /// The signature names a key the app does not list.
    case unlistedKey
    /// The system refused to import the listed key: the resource file is wrong, not the manifest.
    case unimportableKey
    /// The listed key is smaller than the minimum.
    case weakKey
    /// The signature does not cover the manifest's bytes under the key it names.
    case mismatch
}

public enum Signatures {
    /// The pinned allow-list's one scheme: RSASSA-PKCS1-v1_5 with SHA-256, verified by the system's Security framework.
    public static let scheme = "rsa-v1_5-sha256"
    public static let minimumKeyBits = 2048

    /// Verifies that the signature covers the `manifest` string as received, under the key its `keyId` names.
    /// Throws the refusal otherwise.
    public static func verifyManifestSignature(_ envelope: ManifestEnvelope, publicKeys: [DevicePublicKey]) throws {
        guard let signature = envelope.signature else { throw SignatureRefusal.unsigned }
        let prefix = "\(scheme):"
        guard signature.value.hasPrefix(prefix) else { throw SignatureRefusal.unknownScheme }
        guard let listed = publicKeys.first(where: { $0.keyId == signature.keyId }) else { throw SignatureRefusal.unlistedKey }
        guard let key = importPublicKey(listed) else { throw SignatureRefusal.unimportableKey }
        guard SecKeyGetBlockSize(key) * 8 >= minimumKeyBits else { throw SignatureRefusal.weakKey }
        guard let value = Data(base64Encoded: String(signature.value.dropFirst(prefix.count))),
              SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(envelope.manifest.utf8) as CFData, value as CFData, nil) else {
            throw SignatureRefusal.mismatch
        }
    }

    // The system imports the PKCS #1 DER as it stands; no ASN.1 is handled here.
    static func importPublicKey(_ publicKey: DevicePublicKey) -> SecKey? {
        guard let der = Data(base64Encoded: publicKey.der) else { return nil }
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        return SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil)
    }
}
