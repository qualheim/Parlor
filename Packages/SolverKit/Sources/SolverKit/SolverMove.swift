// Copyright © 2025 Parlor. All rights reserved.

import Foundation
import EngineCore

/// A game-agnostic move handle the solver can surface as a hint.
///
/// This wraps `AnyGameAction` from EngineCore to provide a solver-specific move type
/// that is decoupled from any particular game's action types.
public struct SolverMove: Codable, Sendable, Equatable {
    /// The type-erased game action.
    public let encoded: AnyGameAction

    public init(encoded: AnyGameAction) {
        self.encoded = encoded
    }

    /// Create a `SolverMove` from a concrete game action.
    public init<Action: GameAction>(_ action: Action) throws {
        self.encoded = try AnyGameAction(action)
    }

    /// Recover the concrete action, decoding the payload as `Action`.
    public func decode<Action: GameAction>(as type: Action.Type) throws -> Action {
        try encoded.decode(as: type)
    }
}
