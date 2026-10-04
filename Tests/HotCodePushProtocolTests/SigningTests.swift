import Security
import XCTest
@testable import HotCodePushProtocol

final class SigningTests: XCTestCase {
    private let key = SigningFixture.keyA
    private let other = SigningFixture.keyB

    private func refusal(of envelope: ManifestEnvelope, publicKeys: [DevicePublicKey]) -> SignatureRefusal? {
        do {
            try Signatures.verifyManifestSignature(envelope, publicKeys: publicKeys)
            return nil
        } catch {
            return error as? SignatureRefusal
        }
    }

    func testShouldVerifyASignatureOverTheManifestStringAsReceived() {
        let envelope = SigningFixture.envelope(manifest: "{\"a\":1}", signedBy: key)
        XCTAssertNil(refusal(of: envelope, publicKeys: [SigningFixture.publicKey(of: key)]))
        let reserialized = ManifestEnvelope(bundleId: envelope.bundleId, createdAt: envelope.createdAt, manifest: "{ \"a\": 1 }", signature: envelope.signature, pack: envelope.pack)
        XCTAssertEqual(refusal(of: reserialized, publicKeys: [SigningFixture.publicKey(of: key)]), .mismatch)
    }

    func testShouldRefuseAnUnsignedEnvelope() {
        let envelope = ManifestEnvelope(bundleId: "b1", createdAt: Fixture.builtAt, manifest: "{}", pack: .init(url: "\(Fixture.filesBaseUrl)/pack", sizeBytes: 0))
        XCTAssertEqual(refusal(of: envelope, publicKeys: [SigningFixture.publicKey(of: key)]), .unsigned)
    }

    func testShouldSelectTheKeyTheKeyIdNamesAndNoOther() {
        let envelope = SigningFixture.envelope(manifest: "{}", signedBy: key)
        XCTAssertNil(refusal(of: envelope, publicKeys: [SigningFixture.publicKey(of: other), SigningFixture.publicKey(of: key)]))
        XCTAssertEqual(refusal(of: envelope, publicKeys: [SigningFixture.publicKey(of: other)]), .unlistedKey)
        let misattributed = ManifestEnvelope(bundleId: envelope.bundleId, createdAt: envelope.createdAt, manifest: envelope.manifest, signature: Signature(keyId: SigningFixture.keyId(of: other), value: envelope.signature!.value), pack: envelope.pack)
        XCTAssertEqual(refusal(of: misattributed, publicKeys: [SigningFixture.publicKey(of: other), SigningFixture.publicKey(of: key)]), .mismatch)
    }

    func testShouldRefuseAValueUnderAnotherSchemeAsUnknown() {
        let envelope = SigningFixture.envelope(manifest: "{}", signedBy: key)
        let value = envelope.signature!.value.replacingOccurrences(of: "\(Signatures.scheme):", with: "ed25519:")
        let relabelled = ManifestEnvelope(bundleId: envelope.bundleId, createdAt: envelope.createdAt, manifest: envelope.manifest, signature: Signature(keyId: envelope.signature!.keyId, value: value), pack: envelope.pack)
        XCTAssertEqual(refusal(of: relabelled, publicKeys: [SigningFixture.publicKey(of: key)]), .unknownScheme)
    }

    func testShouldRefuseAKeyTheSystemCannotImportAsAConfigurationError() {
        let envelope = SigningFixture.envelope(manifest: "{}", signedBy: key)
        let keyId = SigningFixture.keyId(of: key)
        XCTAssertEqual(refusal(of: envelope, publicKeys: [DevicePublicKey(der: "AQID", keyId: keyId)]), .unimportableKey)
        XCTAssertEqual(refusal(of: envelope, publicKeys: [DevicePublicKey(der: "not base64", keyId: keyId)]), .unimportableKey)
    }

    func testShouldRefuseAKeyUnderTheMinimumSize() {
        let weak = SigningFixture.privateKey(bits: 1024)
        let envelope = SigningFixture.envelope(manifest: "{}", signedBy: weak)
        XCTAssertEqual(refusal(of: envelope, publicKeys: [SigningFixture.publicKey(of: weak)]), .weakKey)
    }
}

/// Keys and signatures for the tests, made by the system: an RSA pair, its public key as an iOS resource file carries it and a key id the signature names.
enum SigningFixture {
    static let keyA = privateKey(bits: 2048)
    static let keyB = privateKey(bits: 2048)

    static func privateKey(bits: Int) -> SecKey {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: bits]
        return SecKeyCreateRandomKey(attributes as CFDictionary, nil)!
    }

    /// The public half's PKCS #1 DER, as `SecKeyCopyExternalRepresentation` exports an RSA public key.
    private static func publicKeyDer(of privateKey: SecKey) -> Data {
        return SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(privateKey)!, nil)! as Data
    }

    /// An id the tests assign; a device takes the id from its resource file and never recomputes it.
    static func keyId(of privateKey: SecKey) -> String {
        return "sha256:\(Hashing.sha256Hex(publicKeyDer(of: privateKey)))"
    }

    static func publicKey(of privateKey: SecKey) -> DevicePublicKey {
        return DevicePublicKey(der: publicKeyDer(of: privateKey).base64EncodedString(), keyId: keyId(of: privateKey))
    }

    static func sign(_ manifest: String, with privateKey: SecKey) -> Signature {
        let value = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(manifest.utf8) as CFData, nil)! as Data
        return Signature(keyId: keyId(of: privateKey), value: "\(Signatures.scheme):\(value.base64EncodedString())")
    }

    static func envelope(manifest: String, signedBy privateKey: SecKey) -> ManifestEnvelope {
        return ManifestEnvelope(bundleId: "b1", createdAt: Fixture.builtAt, manifest: manifest, signature: sign(manifest, with: privateKey), pack: .init(url: "\(Fixture.filesBaseUrl)/pack", sizeBytes: 0))
    }
}
