#!/usr/bin/env swift
// Creates the key pair that signs the releases of Claude Profiles.
//
//   swift scripts/release-keygen.swift [private-key-file]
//
// The private key is written outside the repository (by default into
// ~/.claude-profiles/release-ed25519.key) with the rights 0600 and is never
// committed. The public key is printed so it can be pasted into
// scripts/release-public-key.txt.
//
// The file holds the base64 form of the raw 32 bytes of the key, the same
// way scripts/release-sign.swift reads it back.

import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count <= 2 else {
    FileHandle.standardError.write(Data("usage: swift scripts/release-keygen.swift [private-key-file]\n".utf8))
    exit(2)
}

let defaultPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude-profiles/release-ed25519.key")
let path = arguments.count == 2 ? URL(fileURLWithPath: arguments[1]) : defaultPath

let key = Curve25519.Signing.PrivateKey()
let publicKey = key.publicKey.rawRepresentation.base64EncodedString()

try FileManager.default.createDirectory(
    at: path.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try Data(key.rawRepresentation.base64EncodedString().utf8).write(to: path)
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)

print("private key: \(path.path)")
print("public key:  \(publicKey)")
print("")
print("Put the public key into scripts/release-public-key.txt and commit it.")
print("Keep the private key out of the repository.")
