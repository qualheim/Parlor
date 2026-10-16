// Copyright © 2025 Parlor. All rights reserved.

import Foundation

/// Three-valued classification of a solver result.
///
/// - `winnable`: A winning line exists; optionally includes the best first move.
/// - `unwinnable`: Proven: no winning line exists from this position.
/// - `unknown`: Budget exhausted before a proof either way was reached.
public enum SolveResult: Codable, Sendable, Equatable {
    /// A winning line exists; `bestFirstMove` is the recommended first move when known.
    case winnable(bestFirstMove: SolverMove?)

    /// Proven: no winning line exists from this position.
    case unwinnable

    /// Budget exhausted before a proof either way was reached.
    case unknown

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case winnable
        case unwinnable
        case unknown
        case bestFirstMove
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let bestFirstMove = try container.decodeIfPresent(
            SolverMove.self, forKey: .bestFirstMove)
        {
            self = .winnable(bestFirstMove: bestFirstMove)
        } else if try container.decodeNil(forKey: .winnable) {
            self = .winnable(bestFirstMove: nil)
        } else if try container.decodeNil(forKey: .unwinnable) {
            self = .unwinnable
        } else {
            self = .unknown
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .winnable(let bestFirstMove):
            try container.encode(true, forKey: .winnable)
            try container.encodeIfPresent(bestFirstMove, forKey: .bestFirstMove)
        case .unwinnable:
            try container.encode(true, forKey: .unwinnable)
        case .unknown:
            try container.encode(true, forKey: .unknown)
        }
    }
}
