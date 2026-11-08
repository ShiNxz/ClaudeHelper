// Ed25519 signatures for macOS updates. The app checks every downloaded update against the public key it
// was built with, so only a release signed with the matching private key can replace it.
//
//   swift scripts/sign-update.swift generate <private-key-file>   new key pair; prints the public key
//   swift scripts/sign-update.swift sign <file>                    prints the signature (key in RELAY_MAC_UPDATE_KEY)
//   swift scripts/sign-update.swift verify <file> <signature> <public-key>
//
// Keys and signatures are base64. Keep the private key out of the repository: it goes in the
// RELAY_MAC_UPDATE_KEY GitHub secret, and a backup somewhere safe.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 3 else { fail("usage: sign-update.swift generate <key-file> | sign <file> | verify <file> <sig> <pub>") }

switch args[1] {
case "generate":
    let path = args[2]
    if FileManager.default.fileExists(atPath: path) { fail("\(path) exists; not overwriting a key") }
    let key = Curve25519.Signing.PrivateKey()
    FileManager.default.createFile(atPath: path, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                   attributes: [.posixPermissions: 0o600])
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard let b64 = ProcessInfo.processInfo.environment["RELAY_MAC_UPDATE_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
          let raw = Data(base64Encoded: b64), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("RELAY_MAC_UPDATE_KEY is missing or not a base64 Ed25519 private key")
    }
    guard let data = FileManager.default.contents(atPath: args[2]) else { fail("cannot read \(args[2])") }
    guard let signature = try? key.signature(for: data) else { fail("signing failed") }
    print(signature.base64EncodedString())
case "verify":
    guard args.count >= 5, let data = FileManager.default.contents(atPath: args[2]),
          let sig = Data(base64Encoded: args[3]), let pubRaw = Data(base64Encoded: args[4]),
          let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: pubRaw) else { fail("bad arguments") }
    print(pub.isValidSignature(sig, for: data) ? "valid" : "INVALID")
default:
    fail("unknown command \(args[1])")
}
