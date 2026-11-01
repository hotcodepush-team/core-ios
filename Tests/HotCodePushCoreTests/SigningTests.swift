import Security
import XCTest
@testable import HotCodePushCore

final class SigningTests: XCTestCase {
    func testShouldRefuseAKeyTheSystemCannotImportAsAConfigurationError() {
        let envelope = SigningFixture.envelope(manifest: "{}", signedBy: SigningFixture.keyA)
        let keyId = SigningFixture.keyId(of: SigningFixture.keyA)
        XCTAssertEqual(SigningFixture.refusal(of: envelope, publicKeys: [DevicePublicKey(der: "AQID", keyId: keyId)]), .unimportableKey)
        XCTAssertEqual(SigningFixture.refusal(of: envelope, publicKeys: [DevicePublicKey(der: "not base64", keyId: keyId)]), .unimportableKey)
    }
}

enum SigningFixture {
    static let keyA = privateKey(bits: 2048)
    static let keyB = privateKey(bits: 2048)

    static func privateKey(bits: Int) -> SecKey {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: bits]
        return SecKeyCreateRandomKey(attributes as CFDictionary, nil)!
    }

    // `SecKeyCopyExternalRepresentation` exports an RSA public key as PKCS #1 DER.
    private static func publicKeyDer(of privateKey: SecKey) -> Data {
        return SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(privateKey)!, nil)! as Data
    }

    // A device takes the key id from its resource file and never recomputes it.
    static func keyId(of privateKey: SecKey) -> String {
        return "sha256:\(Hashing.sha256Hex(publicKeyDer(of: privateKey)))"
    }

    static func publicKey(of privateKey: SecKey) -> DevicePublicKey {
        return DevicePublicKey(der: publicKeyDer(of: privateKey).base64EncodedString(), keyId: keyId(of: privateKey))
    }

    static func refusal(of envelope: ManifestEnvelope, publicKeys: [DevicePublicKey]) -> SignatureRefusal? {
        do {
            try SignatureVerifier.verifyManifestSignature(envelope, publicKeys: publicKeys)
            return nil
        } catch {
            return error as? SignatureRefusal
        }
    }

    static func sign(_ manifest: String, with privateKey: SecKey) -> Signature {
        let value = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(manifest.utf8) as CFData, nil)! as Data
        return Signature(keyId: keyId(of: privateKey), value: "\(SignatureVerifier.scheme):\(value.base64EncodedString())")
    }

    static func envelope(manifest: String, signedBy privateKey: SecKey) -> ManifestEnvelope {
        return ManifestEnvelope(bundleId: "b1", createdAt: Fixture.builtAt, manifest: manifest, signature: sign(manifest, with: privateKey), pack: .init(url: "\(Fixture.filesBaseUrl)/pack", sizeBytes: 0))
    }
}
