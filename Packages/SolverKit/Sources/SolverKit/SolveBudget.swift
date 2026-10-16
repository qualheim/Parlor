// Copyright © 2025 Parlor. All rights reserved.

import Foundation

/// Deterministic budget for solver runs.
///
/// Controls the computational limits of a solve operation:
/// - `maxNodes`: Authoritative node/iteration cap (deterministic).
/// - `maxDepth`: Optional depth limit for iterative deepening.
/// - `wallClock`: Optional safety valve as a time limit.
public struct SolveBudget: Codable, Sendable, Equatable {
    /// Authoritative deterministic cap on nodes/iterations to explore.
    public var maxNodes: Int

    /// Optional depth limit for iterative deepening searches.
    public var maxDepth: Int?

    /// Optional safety valve: maximum wall-clock time to spend solving.
    public var wallClock: Duration?

    /// Interactive budget optimized for fast responses (≤ 1.0s p95 path).
    ///
    /// Suitable for in-game hint generation where responsiveness matters.
    public static let interactive = SolveBudget(
        maxNodes: 50_000,
        maxDepth: nil,
        wallClock: .seconds(1)
    )

    /// Generation budget for larger offline analysis.
    ///
    /// Suitable for batch processing, deal generation, or deeper analysis.
    public static let generation = SolveBudget(
        maxNodes: 500_000,
        maxDepth: 20,
        wallClock: .seconds(30)
    )

    public init(maxNodes: Int, maxDepth: Int? = nil, wallClock: Duration? = nil) {
        self.maxNodes = maxNodes
        self.maxDepth = maxDepth
        self.wallClock = wallClock
    }
}

// MARK: - Duration (Foundation)

/// A Duration representing a span of time, used for solver time budgets.
public struct Duration: Codable, Sendable, Equatable {
    public let nanoseconds: UInt64

    public init(nanoseconds: UInt64) {
        self.nanoseconds = nanoseconds
    }

    public static func seconds(_ seconds: Int) -> Duration {
        Duration(nanoseconds: UInt64(seconds) * 1_000_000_000)
    }

    public static func milliseconds(_ milliseconds: Int) -> Duration {
        Duration(nanoseconds: UInt64(milliseconds) * 1_000_000)
    }
}
