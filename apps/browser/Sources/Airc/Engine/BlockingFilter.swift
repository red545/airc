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
    func scriptlet(url: String) -> String {
        #if canImport(AircBlocking)
        let bytes = Data(url.utf8)
        let result = bytes.withUnsafeBytes { b in airc_blocking_cosmetics(handle,
            b.baseAddress?.assumingMemoryBound(to: UInt8.self), b.count) }
        let object = (try? JSONSerialization.jsonObject(with: Self.take(result))) as? [String: Any]
        return object?["injected_script"] as? String ?? ""
        #else
        return ""
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

/// One compile per list text (by digest) at a time, shared by its users: the blocking center's filter for a profile
/// and the YouTube scriptlets each profile's engine install builds (fastlaunch: each built its own, one full
/// adblock-rust compile per profile on the launch's path). Finished filters are held weakly: memory stays with the
/// profiles using them.
@MainActor enum SharedBlockingFilters {
    private final class Box { weak var filter: BlockingFilter? }
    private static var finished: [String: Box] = [:]
    private static var running: [String: Task<BlockingFilter, Error>] = [:]

    static func filter(text: String, digest: String) async throws -> BlockingFilter {
        if let f = finished[digest]?.filter { return f }
        let task: Task<BlockingFilter, Error>
        if let r = running[digest] { task = r } else {
            task = Task.detached(priority: .userInitiated) {
                defer { AllocatorCacheFlush.afterCompile() }   // its freed working memory goes back to macOS
                return try BlockingFilter.compile(text)
            }
            running[digest] = task
        }
        do {
            let f = try await task.value
            if running[digest] == task { running[digest] = nil }
            finished = finished.filter { $0.value.filter != nil }
            let box = Box(); box.filter = f; finished[digest] = box
            return f
        } catch {
            if running[digest] == task { running[digest] = nil }
            throw error
        }
    }
}
