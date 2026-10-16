// Copyright © 2025 Parlor. All rights reserved.

import Foundation
import EngineCore

/// Protocol defining what a game must implement for the solver to work on it.
///
/// This is the public surface the solver uses to interact with games — it provides
/// state access, move generation, and game-specific evaluation without exposing
/// the full engine API.
public protocol SolvableGame: Sendable {
    /// The solver's internal node type for this game.
    associatedtype Node: Sendable

    /// The game's state type.
    associatedtype State: GameState

    /// Create a solver node from the game's engine state.
    ///
    /// - Parameter state: The game's current engine state.
    /// - Returns: A solver node representing this position.
    func rootNode(from state: State) -> Node

    /// Compute a canonical hash for memoization.
    ///
    /// - Parameter node: The node to hash.
    /// - Returns: A deterministic hash value for the position.
    func canonicalHash(_ node: Node) -> UInt64

    /// Check if the node represents a winning position.
    ///
    /// - Parameter node: The node to check.
    /// - Returns: `true` if this is a terminal winning state.
    func isWon(_ node: Node) -> Bool

    /// Check if the node represents a dead position (no further moves possible, not won).
    ///
    /// - Parameter node: The node to check.
    /// - Returns: `true` if this is a terminal losing/unwinnable state.
    func isDead(_ node: Node) -> Bool

    /// Generate all legal moves from a node.
    ///
    /// - Parameters:
    ///   - node: The current position.
    ///   - out: Array to append generated moves to.
    func generateMoves(_ node: Node, into out: inout [SolverMove])

    /// Apply a move to a node, producing a new node.
    ///
    /// - Parameters:
    ///   - move: The move to apply.
    ///   - node: The current position.
    /// - Returns: The new position after applying the move.
    func apply(_ move: SolverMove, to node: Node) -> Node

    /// Heuristic evaluation of a node (higher = better for the solver's perspective).
    ///
    /// - Parameter node: The position to evaluate.
    /// - Returns: Integer heuristic value; higher is better.
    func heuristic(_ node: Node) -> Int
}

// MARK: - Default Implementations

extension SolvableGame {
    /// Default implementation generates an empty moves array.
    public func generateMoves(_ node: Node, into out: inout [SolverMove]) {
        out.removeAll()
    }
}
