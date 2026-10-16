// Copyright © 2025 Parlor. All rights reserved.

import Foundation
import EngineCore

/// The main solver driver service.
///
/// Provides both synchronous and cancellable asynchronous solving capabilities
/// for games conforming to `SolvableGame`.
public final class DealSolver<G: SolvableGame> {
    /// The game to solve.
    private let game: G

    /// The transposition table for memoization.
    /// Uses internal locking for thread safety.
    private let transpositionTable: TranspositionTable

    /// Statistics about the search.
    private var stats: SearchStats = SearchStats()

    public init(game: G) {
        self.game = game
        self.transpositionTable = TranspositionTable()
    }

    /// Solve with the given budget.
    ///
    /// - Parameters:
    ///   - state: The initial game state to solve from.
    ///   - budget: Computational limits for the solve.
    /// - Returns: The solve result indicating winnability and best move if known.
    public func solve(_ state: G.State, budget: SolveBudget) -> SolveResult {
        var node = game.rootNode(from: state)
        return solve(node: &node, budget: budget)
    }

    /// Solve from a node directly.
    public func solve(node: inout G.Node, budget: SolveBudget) -> SolveResult {
        // Reset statistics
        stats = SearchStats()
        transpositionTable.clear()

        // Check terminal states first
        if game.isWon(node) {
            return .winnable(bestFirstMove: nil)
        }
        if game.isDead(node) {
            return .unwinnable
        }

        // Use iterative deepening depth-first search with transposition table
        var result: SolveResult = .unknown

        // Start from depth 1 and increase
        let startDepth = 1
        let maxDepth = budget.maxDepth ?? 100  // Reasonable default

        for depth in startDepth...maxDepth {
            let remainingBudget = budget.maxNodes - stats.nodesVisited

            guard remainingBudget > 0 else {
                // Budget exhausted
                break
            }

            // Perform search at this depth
            let (depthResult, _) = search(
                node: &node,
                depth: depth,
                remainingBudget: remainingBudget,
                alpha: Int.min,
                beta: Int.max
            )

            result = depthResult

            // If we found a winning line, we can stop
            if case .winnable = result {
                // Store best move from the transposition table
                let hash = game.canonicalHash(node)
                if let entry = transpositionTable.get(hash), let move = entry.bestMove {
                    return .winnable(bestFirstMove: move)
                }
                return result
            }

            // If unwinnable proven, also stop
            if case .unwinnable = result {
                break
            }
        }

        // If we exhausted the budget without a definite result, return unknown
        if case .unknown = result, budget.maxNodes > 0 && stats.nodesVisited >= budget.maxNodes {
            return .unknown
        }

        // Try to get best move from transposition table
        let hash = game.canonicalHash(node)
        if let entry = transpositionTable.get(hash), let move = entry.bestMove {
            if case .winnable = entry.result {
                return .winnable(bestFirstMove: move)
            }
        }

        return result
    }

    /// Get the current search statistics.
    public func getStats() -> SearchStats {
        return stats
    }

    // MARK: - Internal Search Implementation

    /// Internal search with alpha-beta pruning and transposition table.
    private func search(
        node: inout G.Node,
        depth: Int,
        remainingBudget: Int,
        alpha: Int,
        beta: Int
    ) -> (SolveResult, SolverMove?) {
        // Update statistics
        stats.nodesVisited += 1

        // Check budget
        guard remainingBudget > 0 else {
            return (.unknown, nil)
        }

        // Check terminal states
        if game.isWon(node) {
            stats.terminalStatesReached += 1
            return (.winnable(bestFirstMove: nil), nil)
        }

        if game.isDead(node) {
            stats.deadStatesReached += 1
            return (.unwinnable, nil)
        }

        // Check transposition table
        let hash = game.canonicalHash(node)

        // If we've already visited this position at equal or greater depth, use stored result
        if let entry = transpositionTable.get(hash), entry.depth >= depth {
            switch entry.result {
            case .winnable:
                stats.transpositionsUsed += 1
                return (entry.result, entry.bestMove)
            case .unwinnable:
                stats.transpositionsUsed += 1
                return (entry.result, nil)
            case .unknown:
                break  // Continue search
            }
        }

        // Base case: depth exhausted
        if depth <= 0 {
            // Use heuristic to evaluate
            let score = game.heuristic(node)
            if score > 0 {
                return (.winnable(bestFirstMove: nil), nil)
            }
            return (.unknown, nil)
        }

        // Generate and order moves
        var moves: [SolverMove] = []
        game.generateMoves(node, into: &moves)

        if moves.isEmpty {
            return (.unwinnable, nil)
        }

        // Apply symmetry reduction to moves (skip duplicate empty column destinations)
        moves = applySymmetryReduction(moves, to: node)

        var bestMove: SolverMove? = nil
        var bestScore = Int.min
        var currentAlpha = alpha

        for move in moves {
            var childNode = game.apply(move, to: node)

            // Recursive call
            let (childResult, _) = search(
                node: &childNode,
                depth: depth - 1,
                remainingBudget: remainingBudget - 1,
                alpha: currentAlpha,
                beta: beta
            )

            // Evaluate result
            let score: Int
            switch childResult {
            case .winnable:
                // Found a winning line!
                let entry = TranspositionTable.Entry(
                    hash: hash,
                    depth: depth,
                    result: .winnable(bestFirstMove: move),
                    bestMove: move,
                    remainingBudget: remainingBudget
                )
                transpositionTable.set(entry)
                return (.winnable(bestFirstMove: move), move)
            case .unwinnable:
                score = -1000  // Penalty for losing branch
            case .unknown:
                score = game.heuristic(childNode)
            }

            if score > bestScore {
                bestScore = score
                bestMove = move
            }

            currentAlpha = max(currentAlpha, score)
            if currentAlpha >= beta {
                // Beta cutoff - prune remaining branches
                break
            }
        }

        // Store result in transposition table
        let result: SolveResult
        if bestScore == Int.min {
            result = .unwinnable
        } else if bestScore > 0 {
            result = .winnable(bestFirstMove: bestMove)
        } else {
            result = .unknown
        }

        let entry = TranspositionTable.Entry(
            hash: hash,
            depth: depth,
            result: result,
            bestMove: bestMove,
            remainingBudget: remainingBudget
        )
        transpositionTable.set(entry)

        return (result, bestMove)
    }

    /// Apply symmetry reduction to moves.
    /// Filters out duplicate moves that would explore equivalent positions.
    private func applySymmetryReduction(_ moves: [SolverMove], to node: G.Node) -> [SolverMove] {
        // For now, return all moves - symmetry reduction is game-specific
        // and implemented in the per-game SolvableGame conformance
        return moves
    }
}

// MARK: - Search Statistics

/// Statistics collected during search.
public struct SearchStats: Sendable {
    public var nodesVisited: Int = 0
    public var terminalStatesReached: Int = 0
    public var deadStatesReached: Int = 0
    public var transpositionsUsed: Int = 0

    public init() {}
}

// MARK: - Solver Errors

public enum SolverError: Error, Sendable {
    case budgetExceeded
    case invalidState
    case noMovesAvailable
}
