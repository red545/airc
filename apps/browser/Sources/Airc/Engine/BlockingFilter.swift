// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation
#if canImport(AircBlocking)
import AircBlocking
#endif

/// The same bounded C ABI on both engines. Chromium links it through its GN
/// graph; the standalone WebKit build links the pinned Cargo static library.
final class BlockingFilter: @unchecked Sendable {
    enum Failure: Error { case unavailable, invalidRules, invalidOutput }
    #if canImport(AircBlocking)
    private let handle: OpaquePointer
    private init(handle: OpaquePointer) { self.handle = handle }
    deinit { airc_blocking_destroy(handle) }
    #endif

    static func compile(_ text: String) throws -> BlockingFilter {
        #if canImport(AircBlocking)
        let bytes = Data(text.utf8)
        let pointer = bytes.withUnsafeBytes { b in airc_blocking_create(b.baseAddress?.assumingMemoryBound(to: UInt8.self), b.count) }
        guard let pointer else { throw Failure.invalidRules }
        return BlockingFilter(handle: pointer)
        #else
        throw Failure.unavailable
        #endif
    }
    func cosmetics(url: String, tokens: String? = nil) -> [String] {
        #if canImport(AircBlocking)
        let bytes = Data(url.utf8)
        if let tokens {
            let tokens = Data(tokens.utf8)
            let result = bytes.withUnsafeBytes { b in tokens.withUnsafeBytes { t in
                airc_blocking_generic_cosmetics(handle, b.baseAddress?.assumingMemoryBound(to: UInt8.self), b.count,
                    t.baseAddress?.assumingMemoryBound(to: UInt8.self), t.count)
            } }
            return (try? JSONSerialization.jsonObject(with: Self.take(result))) as? [String] ?? []
        }
        let result = bytes.withUnsafeBytes { b in airc_blocking_cosmetics(handle, b.baseAddress?.assumingMemoryBound(to: UInt8.self), b.count) }
        let object = (try? JSONSerialization.jsonObject(with: Self.take(result))) as? [String: Any]
        return object?["hide_selectors"] as? [String] ?? []
        #else
        return []
        #endif
    }
    static func webKitRules(_ text: String) throws -> Data {
        #if canImport(AircBlocking)
        let bytes = Data(text.utf8)
        return try bytes.withUnsafeBytes { b in
            try take(airc_blocking_webkit_rules(b.baseAddress?.assumingMemoryBound(to: UInt8.self), b.count))
        }
        #else
        throw Failure.unavailable
        #endif
    }
    #if canImport(AircBlocking)
    private static func take(_ value: AircBlockingBytes) throws -> Data {
        defer { airc_blocking_bytes_free(value) }
        guard let data = value.data else { throw Failure.invalidOutput }
        return Data(bytes: data, count: value.len)
    }
    #endif
}
