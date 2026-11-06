// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
// Opt-in fallback for a locked login keychain. Never prints private material.
import Foundation
import CryptoKit
import Darwin
umask(0o077)
let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("arcfork/secrets")
try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:dir.path)
let path=dir.appendingPathComponent("sparkle_ed25519_private")
let key:Curve25519.Signing.PrivateKey
if FileManager.default.fileExists(atPath:path.path) {
 key = try Curve25519.Signing.PrivateKey(rawRepresentation:Data(base64Encoded:String(contentsOf:path,encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines))!)
} else {
 key = Curve25519.Signing.PrivateKey()
 try key.rawRepresentation.base64EncodedData().write(to:path,options:.withoutOverwriting)
}
try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
print(key.publicKey.rawRepresentation.base64EncodedString())
