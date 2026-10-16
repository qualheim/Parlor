// Copyright © 2025 Parlor. All rights reserved.

import Foundation

/// Symmetry reduction utilities for the solver.
///
/// This implements:
/// - Equal empty columns are interchangeable
/// - Interchangeable suits should be collapsed
public struct SymmetryReduction {

    /// Information about columns for symmetry analysis.
    public struct ColumnInfo: Sendable, Equatable, Hashable {
        /// The number of cards in the column
        public let cardCount: Int
        /// Top card code if any (for empty column detection)
        public let topCard: CardCode?
        /// Whether the column is empty
        public var isEmpty: Bool { cardCount == 0 }

        public init(cardCount: Int, topCard: CardCode?) {
            self.cardCount = cardCount
            self.topCard = topCard
        }
    }

    /// Group identical empty columns to find interchangeable destinations.
    /// Returns the indices of empty columns, with redundant ones marked.
    ///
    /// - Parameter columns: Array of column information
    /// - Returns: Array of booleans indicating whether each column is "canonical"
    ///            (true = should be explored, false = symmetry duplicate)
    public static func canonicalizeEmptyColumns(_ columns: [ColumnInfo]) -> [Bool] {
        var result = [Bool](repeating: false, count: columns.count)
        var seenEmptyIndices: [Int] = []

        for (i, col) in columns.enumerated() {
            if col.isEmpty {
                // Check if we've seen an equivalent empty column
                let alreadySeen = seenEmptyIndices.first { existingIdx in
                    columns[existingIdx].isEmpty
                }

                if alreadySeen == nil {
                    // First empty column - this is canonical
                    result[i] = true
                    seenEmptyIndices.append(i)
                }
                // else: duplicate empty column, stays false
            } else {
                // Non-empty columns are always canonical
                result[i] = true
            }
        }

        return result
    }

    /// Analyze suit symmetry for a game state.
    /// Returns a normalized form that collapses equivalent suits.
    ///
    /// This is useful for games like Spider where suit identity matters less
    /// than the relative ordering when suits are interchangeable.
    public struct SuitSymmetryInfo: Sendable, Equatable {
        /// Map from original suit to normalized suit (0, 1, 2, ...)
        public let suitMap: [UInt8: UInt8]
        /// The number of unique suits after normalization
        public let uniqueSuitCount: Int

        public init(suitMap: [UInt8: UInt8], uniqueSuitCount: Int) {
            self.suitMap = suitMap
            self.uniqueSuitCount = uniqueSuitCount
        }
    }

    /// Compute suit symmetry for a Spider-like game.
    /// When fewer suits are in play, multiple original suits map to the same normalized suit.
    public static func computeSuitSymmetry(
        originalSuitCount: Int,
        activeSuits: Set<UInt8>
    ) -> SuitSymmetryInfo {
        // Map original suits to normalized suits
        // For Spider with 1-suit: all suits map to 0
        // For Spider with 2-suit: suits 0,1 map to 0; suits 2,3 map to 1
        var suitMap: [UInt8: UInt8] = [:]

        let normalizedCount: UInt8

        switch originalSuitCount {
        case 1:
            normalizedCount = 1
            // All suits collapse to 0
            for suit in 0..<4 {
                suitMap[UInt8(suit)] = 0
            }
        case 2:
            normalizedCount = 2
            // Spades+Hearts -> 0, Diamonds+Clubs -> 1 (or similar grouping)
            // Use a stable grouping
            suitMap[0] = 0  // clubs
            suitMap[1] = 1  // diamonds
            suitMap[2] = 0  // hearts
            suitMap[3] = 1  // spades
        default:
            normalizedCount = 4
            // No collapse
            for suit in 0..<4 {
                suitMap[UInt8(suit)] = UInt8(suit)
            }
        }

        return SuitSymmetryInfo(suitMap: suitMap, uniqueSuitCount: Int(normalizedCount))
    }

    /// Normalize a card code based on suit symmetry.
    public static func normalizeCard(_ card: CardCode, symmetry: SuitSymmetryInfo) -> CardCode {
        let normalizedSuit = symmetry.suitMap[card.suit] ?? card.suit
        return CardCode(suit: normalizedSuit, rank: card.rank)
    }
}

// MARK: - Canonical Column Ordering

extension SymmetryReduction {
    /// Sort columns by a stable key for canonical ordering.
    /// Empty columns sort first, then by card count, then by top card.
    public static func sortColumnsCanonical(_ columns: [ColumnInfo]) -> [Int] {
        // Create index-value pairs and sort by stable key
        let indexed = columns.enumerated().map { ($0.offset, $0.element) }

        let sorted = indexed.sorted { a, b in
            // Empty columns first
            if a.1.isEmpty && !b.1.isEmpty { return true }
            if !a.1.isEmpty && b.1.isEmpty { return false }

            // Then by card count
            if a.1.cardCount != b.1.cardCount {
                return a.1.cardCount < b.1.cardCount
            }

            // Then by top card (if any)
            if let aTop = a.1.topCard, let bTop = b.1.topCard {
                return aTop.rawValue < bTop.rawValue
            }
            if a.1.topCard != nil { return true }
            if b.1.topCard != nil { return false }

            // Finally by original index (stable)
            return a.0 < b.0
        }

        return sorted.map { $0.0 }
    }
}
