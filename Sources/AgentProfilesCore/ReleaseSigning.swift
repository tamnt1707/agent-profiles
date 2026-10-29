import CryptoKit
import Foundation

/// The signature of a release: Ed25519 over the exact bytes of the archive.
///
/// The public key is stored in the `Info.plist` of the app (`UpdatePublicKey`)
/// and in `scripts/release-public-key.txt`. The private key never enters the
/// repository: `scripts/release.sh` reads it from `$RELEASE_KEY_FILE`.
public enum ReleaseSigning {
    /// Signs the bytes of a release archive.
    public static func sign(_ data: Data, privateKey: Curve25519.Signing.PrivateKey) throws -> Data {
        try privateKey.signature(for: data)
    }

    /// The base64 form of a public key, the way the `Info.plist` stores it.
    public static func publicKeyBase64(_ key: Curve25519.Signing.PublicKey) -> String {
        key.rawRepresentation.base64EncodedString()
    }

    /// The base64 form of a private key, the way the key file stores it.
    public static func privateKeyBase64(_ key: Curve25519.Signing.PrivateKey) -> String {
        key.rawRepresentation.base64EncodedString()
    }

    /// Reads a public key from its base64 form.
    public static func publicKey(fromBase64 text: String) -> Curve25519.Signing.PublicKey? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed), data.count == 32 else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: data)
    }

    /// Reads a private key from its base64 form.
    public static func privateKey(fromBase64 text: String) -> Curve25519.Signing.PrivateKey? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed), data.count == 32 else { return nil }
        return try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }

    /// Checks a signature over the bytes of a release archive.
    ///
    /// Returns `false` for a broken key and for a signature that does not
    /// match; the caller must never offer an "install anyway" way out.
    public static func verify(_ data: Data, signature: Data, publicKeyBase64: String) -> Bool {
        guard let key = publicKey(fromBase64: publicKeyBase64) else { return false }
        return key.isValidSignature(signature, for: data)
    }
}
