// Copyright © 2025 Parlor. All rights reserved.

import Foundation
import EngineCore

/// Provides canonical serialization and hashing for game states.
///
/// This implements the ADR-0002 discipline:
/// - Columns sorted by stable key
/// - Foundations in fixed suit order
/// - No wall-clock or address-derived fields
public struct CanonicalHash {

    /// A fixed seed for the mixing function to ensure stability across runs.
    /// This is the SplitMix64 fixed seed for determinism.
    public static let fixedSeed: UInt64 = 0x9E3779B97F4A7C15

    /// Compute a 64-bit canonical hash for a game node.
    ///
    /// The hash uses a stable mixing function (SplitMix64-style) so it is
    /// reproducible across runs and platforms.
    ///
    /// - Parameters:
    ///   - node: The game node to hash
    ///   - serialize: A closure that produces the canonical serialization bytes
    /// - Returns: A deterministic 64-bit hash
    public static func compute<Node: Sendable>(
        for node: Node,
        serialize: (Node) -> Data
    ) -> UInt64 {
        let data = serialize(node)
        return mix64(data)
    }

    /// SplitMix64-inspired mixing function for deterministic 64-bit output.
    /// Uses the fixed seed and a standard mixing pattern.
    private static func mix64(_ data: Data) -> UInt64 {
        var hash = fixedSeed

        // Process data in 8-byte chunks using FNV-1a inspired mixing
        let bytes = [UInt8](data)
        var index = 0

        // FNV-1a basis and prime (standard constants)
        let fnvOffset: UInt64 = 0xcbf29ce484222325
        let fnvPrime: UInt64 = 0x100000001b3
        hash = fnvOffset

        while index < bytes.count {
            hash ^= UInt64(bytes[index])
            hash = hash &* fnvPrime
            index += 1
        }

        // Final Mix64 avalanche to improve distribution
        hash ^= hash >> 33
        hash = hash &* 0xff51afd7ed558ccd
        hash ^= hash >> 33
        hash = hash &* 0xc4ceb9fe1a85ec53
        hash ^= hash >> 33

        return hash
    }
}

// MARK: - Card Code Utilities

/// Card code representation for canonical serialization.
/// Uses 0-51 encoding: suit * 13 + (rank - 1)
public struct CardCode: Sendable, Codable, Equatable, Hashable {
    public let rawValue: UInt8  // 0-51 for standard deck

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public init(suit: UInt8, rank: UInt8) {
        // rank: 1=Ace, ..., 13=King
        self.rawValue = (suit % 4) * 13 + (rank - 1) % 13
    }

    public var suit: UInt8 {
        rawValue / 13
    }

    public var rank: UInt8 {
        rawValue % 13 + 1  // 1=Ace, ..., 13=King
    }

    /// Serialize to a single byte for canonical representation.
    public var serialized: UInt8 {
        rawValue
    }
}

/// Extension for Spider's 104-card deck (indices 0-103)
extension CardCode {
    public init(spiderCode: UInt8) {
        // Spider uses 0-103 encoding
        self.rawValue = spiderCode % 104
    }

    public var spiderCode: UInt8 {
        rawValue
    }
}
