// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation
import CryptoKit
let encoded=try String(contentsOfFile:CommandLine.arguments[1],encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)
guard let data=Data(base64Encoded:encoded), data.count==32 else { fatalError("Expected a base64-encoded 32-byte Sparkle seed") }
let key=try Curve25519.Signing.PrivateKey(rawRepresentation:data)
print(key.publicKey.rawRepresentation.base64EncodedString())
