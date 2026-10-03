import CryptoKit
import XCTest
@testable import HotCodePushProtocol

final class SigningTests: XCTestCase {
    private let privateKey = Curve25519.Signing.PrivateKey()

    func testShouldParseACanonicalSelfDescribingValue() throws {
        let bytes = Data([1, 2, 3, 250])
        let parsed = try XCTUnwrap(SelfDescribingBytes.parse("ed25519:\(bytes.base64EncodedString())"))
        XCTAssertEqual(parsed.scheme, .ed25519)
        XCTAssertEqual(parsed.bytes, bytes)
    }

    func testShouldRefuseAValueOutsideTheAllowListOrOffCanonicalBase64() {
        XCTAssertNil(SelfDescribingBytes.parse("ecdsa-p256-sha256:AQID"))
        XCTAssertNil(SelfDescribingBytes.parse("rsa-v1_5-sha256:AQID"))
        XCTAssertNil(SelfDescribingBytes.parse("ed25519"))
        XCTAssertNil(SelfDescribingBytes.parse("ed25519:AQI"), "padding is missing")
        XCTAssertNil(SelfDescribingBytes.parse("ed25519:AB=="), "the unused bits are not zero")
        XCTAssertNil(SelfDescribingBytes.parse("ed25519:AQ ID"))
    }

    func testShouldAcceptAPublicKeyOnlyWhenItsBytesHaveTheSchemesLength() {
        XCTAssertNotNil(SigningKeys.parsePublicKey(SigningFixture.publicKey(of: privateKey)))
        XCTAssertNil(SigningKeys.parsePublicKey("ed25519:\(Data(repeating: 1, count: 31).base64EncodedString())"))
    }

    func testShouldFingerprintAKeyAsTheSha256OfItsBytes() throws {
        let key = try XCTUnwrap(SigningKeys.parsePublicKey(SigningFixture.publicKey(of: privateKey)))
        XCTAssertEqual(SigningKeys.fingerprint(of: key), "sha256:\(Hashing.sha256Hex(privateKey.publicKey.rawRepresentation))")
    }

    func testShouldVerifyASignatureOverTheManifestStringAsReceived() throws {
        let envelope = SigningFixture.envelope(manifest: "{\"a\":1}", signedBy: privateKey)
        XCTAssertTrue(Signatures.verifyManifestSignature(envelope, publicKeys: [SigningFixture.publicKey(of: privateKey)]))
        let reserialized = ManifestEnvelope(bundleId: envelope.bundleId, createdAt: envelope.createdAt, manifest: "{ \"a\": 1 }", signature: envelope.signature, pack: envelope.pack)
        XCTAssertFalse(Signatures.verifyManifestSignature(reserialized, publicKeys: [SigningFixture.publicKey(of: privateKey)]))
    }

    func testShouldVerifyAgainstNoKeyWhenTheEnvelopeIsUnsigned() {
        let envelope = ManifestEnvelope(bundleId: "b1", createdAt: Fixture.builtAt, manifest: "{}", pack: .init(url: "\(Fixture.filesBaseUrl)/pack", sizeBytes: 0))
        XCTAssertFalse(Signatures.verifyManifestSignature(envelope, publicKeys: [SigningFixture.publicKey(of: privateKey)]))
    }

    func testShouldSelectTheKeyTheKeyIdNamesAndNoOther() {
        let other = Curve25519.Signing.PrivateKey()
        let envelope = SigningFixture.envelope(manifest: "{}", signedBy: privateKey)
        XCTAssertTrue(Signatures.verifyManifestSignature(envelope, publicKeys: ["not a key", SigningFixture.publicKey(of: other), SigningFixture.publicKey(of: privateKey)]))
        XCTAssertFalse(Signatures.verifyManifestSignature(envelope, publicKeys: [SigningFixture.publicKey(of: other)]))
        let misattributed = ManifestEnvelope(bundleId: envelope.bundleId, createdAt: envelope.createdAt, manifest: envelope.manifest, signature: Signature(keyId: SigningFixture.keyId(of: other), value: envelope.signature!.value), pack: envelope.pack)
        XCTAssertFalse(Signatures.verifyManifestSignature(misattributed, publicKeys: [SigningFixture.publicKey(of: other), SigningFixture.publicKey(of: privateKey)]))
    }
}

/// Keys and signatures for the tests: a CryptoKit pair, its public key and fingerprint as the wire carries them.
enum SigningFixture {
    static func publicKey(of privateKey: Curve25519.Signing.PrivateKey) -> String {
        return "ed25519:\(privateKey.publicKey.rawRepresentation.base64EncodedString())"
    }

    static func keyId(of privateKey: Curve25519.Signing.PrivateKey) -> String {
        return "sha256:\(Hashing.sha256Hex(privateKey.publicKey.rawRepresentation))"
    }

    static func sign(_ manifest: String, with privateKey: Curve25519.Signing.PrivateKey) -> Signature {
        let value = try! privateKey.signature(for: Data(manifest.utf8))
        return Signature(keyId: keyId(of: privateKey), value: "ed25519:\(value.base64EncodedString())")
    }

    static func envelope(manifest: String, signedBy privateKey: Curve25519.Signing.PrivateKey) -> ManifestEnvelope {
        return ManifestEnvelope(bundleId: "b1", createdAt: Fixture.builtAt, manifest: manifest, signature: sign(manifest, with: privateKey), pack: .init(url: "\(Fixture.filesBaseUrl)/pack", sizeBytes: 0))
    }
}
