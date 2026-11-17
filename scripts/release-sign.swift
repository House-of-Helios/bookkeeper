// Release signing for Bookkeeper's GitHub updates (Ed25519, CryptoKit).
//
//   swift scripts/release-sign.swift keygen            → prints a new private key (base64) and its public key
//   … | swift scripts/release-sign.swift public        → prints the public key of the key on stdin
//   … | swift scripts/release-sign.swift sign <version> <sha256-hex>
//                                                      → prints the signature (base64)
//
// The private key is read from stdin, never argv: any process on the Mac can read another's
// arguments (`ps`) while it runs.
//   swift scripts/release-sign.swift verify <pub-b64> <version> <sha256-hex> <sig-b64>
//                                                      → exit 0 when it verifies
//
// The app checks the signature over "<version>\n<sha256>" with the public key baked into
// ReleaseFeed.swift, so a zip can't be relabelled as another version. The private key
// lives only in this Mac's login Keychain (scripts/release.sh reads it); never in a file.
import CryptoKit
import Foundation

let args = CommandLine.arguments
func die(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(1) }
func key() -> Curve25519.Signing.PrivateKey {
    let b64 = (readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespaces)
    guard let d = Data(base64Encoded: b64), let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: d)
    else { die("not a private key") }
    return k
}
switch args.count > 1 ? args[1] : "" {
case "keygen":
    let k = Curve25519.Signing.PrivateKey()
    print(k.rawRepresentation.base64EncodedString())
    print(k.publicKey.rawRepresentation.base64EncodedString())
case "public" where args.count == 2:
    print(key().publicKey.rawRepresentation.base64EncodedString())
case "sign" where args.count == 4:
    let message = Data("\(args[2])\n\(args[3].lowercased())".utf8)
    guard let sig = try? key().signature(for: message) else { die("signing failed") }
    print(sig.base64EncodedString())
case "verify" where args.count == 6:
    guard let pd = Data(base64Encoded: args[2]), let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: pd),
          let sig = Data(base64Encoded: args[5]),
          pub.isValidSignature(sig, for: Data("\(args[3])\n\(args[4].lowercased())".utf8))
    else { die("signature does not verify") }
    print("verifies")
default:
    die("usage: release-sign.swift keygen | public (key on stdin) | sign <version> <sha256> (key on stdin) | verify <pub> <version> <sha256> <sig>")
}
