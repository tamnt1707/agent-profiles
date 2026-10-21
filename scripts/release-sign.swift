#!/usr/bin/env swift
// Signs a file with the private key of the releases.
//
//   swift scripts/release-sign.swift <private-key-file> <file> <signature-file>
//
// The signature is the base64 form of the Ed25519 signature over the exact
// bytes of the file. The app checks it with the public key of its
// Info.plist (UpdatePublicKey) and refuses the update when it does not
// match.

import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    FileHandle.standardError.write(
        Data("usage: swift scripts/release-sign.swift <private-key-file> <file> <signature-file>\n".utf8)
    )
    exit(2)
}

let keyPath = URL(fileURLWithPath: arguments[1])
let input = URL(fileURLWithPath: arguments[2])
let output = URL(fileURLWithPath: arguments[3])

guard let keyText = try? String(contentsOf: keyPath, encoding: .utf8) else {
    FileHandle.standardError.write(Data("cannot read the private key \(keyPath.path)\n".utf8))
    exit(1)
}
let trimmed = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
guard let raw = Data(base64Encoded: trimmed), raw.count == 32,
      let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
else {
    FileHandle.standardError.write(Data("the private key \(keyPath.path) is broken\n".utf8))
    exit(1)
}

guard let data = try? Data(contentsOf: input) else {
    FileHandle.standardError.write(Data("cannot read \(input.path)\n".utf8))
    exit(1)
}

let signature = try privateKey.signature(for: data)
try Data(signature.base64EncodedString().utf8).write(to: output)

print("signed \(input.lastPathComponent) -> \(output.lastPathComponent)")
