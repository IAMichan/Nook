#!/usr/bin/env swift
// Signs Nook's release .zip so a downloaded Nook can check an update before installing it (docs/UPDATES.md, "Release
// builds"). Ed25519 with CryptoKit; keys are base64 of their 32 raw bytes, the signature base64 of its 64 bytes.
//
//   swift scripts/sign-update.swift generate
//       prints a new key pair: the private key goes into the repository secret NOOK_UPDATE_SIGNING_KEY, the public key
//       into the repository variable NOOK_UPDATE_PUBLIC_KEY (release builds put it into Info.plist).
//   NOOK_UPDATE_SIGNING_KEY=… [NOOK_UPDATE_PUBLIC_KEY=…] swift scripts/sign-update.swift sign Nook-1.0.0-macOS.zip
//       prints the signature (the release's .zip.sig). With NOOK_UPDATE_PUBLIC_KEY set, it refuses a private key that
//       does not belong to it, so a release never carries a signature its own builds reject.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "generate":
    let key = Curve25519.Signing.PrivateKey()
    print("NOOK_UPDATE_SIGNING_KEY (secret): \(key.rawRepresentation.base64EncodedString())")
    print("NOOK_UPDATE_PUBLIC_KEY (variable): \(key.publicKey.rawRepresentation.base64EncodedString())")
case "sign":
    guard arguments.count == 2 else { fail("usage: sign-update.swift sign <file>") }
    let path = arguments[1]
    let environment = ProcessInfo.processInfo.environment
    guard let text = environment["NOOK_UPDATE_SIGNING_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
          let raw = Data(base64Encoded: text), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else { fail("NOOK_UPDATE_SIGNING_KEY is not a base64 Ed25519 private key (32 bytes).") }
    if let expected = environment["NOOK_UPDATE_PUBLIC_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !expected.isEmpty,
       expected != key.publicKey.rawRepresentation.base64EncodedString() {
        fail("NOOK_UPDATE_SIGNING_KEY does not belong to NOOK_UPDATE_PUBLIC_KEY.")
    }
    guard let data = FileManager.default.contents(atPath: path) else { fail("Cannot read \(path).") }
    guard let signature = try? key.signature(for: data), key.publicKey.isValidSignature(signature, for: data) else {
        fail("Signing failed.")
    }
    print(signature.base64EncodedString())
default:
    fail("usage: sign-update.swift generate | sign <file>")
}
