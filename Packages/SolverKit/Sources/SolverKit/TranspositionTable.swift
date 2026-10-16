// Copyright © 2025 Parlor. All rights reserved.

import Foundation

/// A transposition (visited) table for the solver.
///
/// Stores hash → (depth, result, bestMove) entries with deterministic
/// eviction handling collisions appropriately.
public final class TranspositionTable: Sendable {

    /// Entry stored in the transposition table.
    public struct Entry: Sendable {
        /// The canonical hash of the position.
        public let hash: UInt64
        /// The depth at which this position was explored.
        public let depth: Int
        /// The result at this position.
        public let result: SolveResult
        /// The best move from this position (if known).
        public let bestMove: SolverMove?
        /// The remaining budget when this was stored.
        public let remainingBudget: Int

        public init(
            hash: UInt64,
            depth: Int,
            result: SolveResult,
            bestMove: SolverMove?,
            remainingBudget: Int
        ) {
            self.hash = hash
            self.depth = depth
            self.result = result
            self.bestMove = bestMove
            self.remainingBudget = remainingBudget
        }
    }

    /// The storage for the transposition table.
    private final class Storage: @unchecked Sendable {
        private var table: [UInt64: Entry]
        private let lock = NSLock()

        init(capacity: Int) {
            // Use a load factor of 0.75 to reduce collisions
            table = [UInt64: Entry](minimumCapacity: capacity / 3 * 4)
        }

        func get(_ hash: UInt64) -> Entry? {
            lock.lock()
            defer { lock.unlock() }
            return table[hash]
        }

        func set(_ entry: Entry) {
            lock.lock()
            defer { lock.unlock() }
            // Simple replacement strategy: newer entries replace older ones
            // This provides deterministic behavior
            table[entry.hash] = entry
        }

        func count() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return table.count
        }

        func clear() {
            lock.lock()
            defer { lock.unlock() }
            table.removeAll()
        }
    }

    private let storage: Storage

    /// Create a transposition table with the given capacity.
    public init(capacity: Int = 1_000_000) {
        self.storage = Storage(capacity: capacity)
    }

    /// Look up an entry by hash.
    /// - Parameter hash: The canonical hash to look up.
    /// - Returns: The stored entry if found.
    public func get(_ hash: UInt64) -> Entry? {
        storage.get(hash)
    }

    /// Store an entry in the table.
    /// - Parameter entry: The entry to store.
    public func set(_ entry: Entry) {
        storage.set(entry)
    }

    /// Check if we should skip expanding a node based on the transposition table.
    /// Returns true if the node should be skipped.
    /// - Parameters:
    ///   - hash: The canonical hash of the node.
    ///   - depth: The current depth of the search.
    ///   - remainingBudget: The remaining node budget.
    /// - Returns: true if we should skip this node.
    public func shouldSkip(hash: UInt64, depth: Int, remainingBudget: Int) -> Bool {
        guard let entry = get(hash) else {
            return false
        }

        // Skip if we've already visited at equal or greater depth/budget
        if entry.depth >= depth && entry.remainingBudget >= remainingBudget {
            return true
        }

        // Also skip if we already have a definite result (winnable or unwinnable)
        switch entry.result {
        case .winnable:
            return true
        case .unwinnable:
            // For unwinnable, only skip if we explored at least as deeply
            return entry.depth >= depth
        case .unknown:
            return false
        }
    }

    /// Get the stored result for a hash if available.
    /// - Parameter hash: The canonical hash.
    /// - Returns: The stored result, if any.
    public func getResult(_ hash: UInt64) -> SolveResult? {
        get(hash)?.result
    }

    /// Get the best move for a hash if available.
    /// - Parameter hash: The canonical hash.
    /// - Returns: The stored best move, if any.
    public func getBestMove(_ hash: UInt64) -> SolverMove? {
        get(hash)?.bestMove
    }

    /// Clear the transposition table.
    public func clear() {
        storage.clear()
    }

    /// Get the current number of entries.
    public var count: Int {
        storage.count()
    }
}

// MARK: - Thread-Safe Actor Alternative

/// An actor-based alternative for the transposition table
/// for use in async contexts.
public actor TranspositionTableActor {
    private var table: [UInt64: TranspositionTable.Entry] = [:]

    public init(capacity: Int = 1_000_000) {
        // Pre-allocate for efficiency
    }

    public func get(_ hash: UInt64) -> TranspositionTable.Entry? {
        table[hash]
    }

    public func set(_ entry: TranspositionTable.Entry) {
        table[entry.hash] = entry
    }

    public func shouldSkip(hash: UInt64, depth: Int, remainingBudget: Int) -> Bool {
        guard let entry = table[hash] else {
            return false
        }

        if entry.depth >= depth && entry.remainingBudget >= remainingBudget {
            return true
        }

        switch entry.result {
        case .winnable:
            return true
        case .unwinnable:
            return entry.depth >= depth
        case .unknown:
            return false
        }
    }

    public func getResult(_ hash: UInt64) -> SolveResult? {
        table[hash]?.result
    }

    public func getBestMove(_ hash: UInt64) -> SolverMove? {
        table[hash]?.bestMove
    }

    public func clear() {
        table.removeAll()
    }

    public var count: Int {
        table.count
    }
}
