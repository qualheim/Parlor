// Copyright © 2025 Parlor. All rights reserved.

import Foundation
import EngineCore

// MARK: - TriPeaks Solver Node

/// Compact solver node encoding for TriPeaks solitaire.
/// Uses 28-bit mask for peak-remaining, current card, stock cursor, and wrap option.
public struct TriPeaksSolverNode: Sendable, Codable, Equatable {
    /// 28-bit mask of peak cards still in play (1 = card present, 0 = removed)
    public var peaksMask: UInt32

    /// Current card code (0-51)
    public var currentCard: UInt8

    /// Stock: remaining cards (face-down)
    public var stock: [UInt8]

    /// Wrap option (K↔A adjacent)
    public var wrapEnabled: Bool

    public init(
        peaksMask: UInt32,
        currentCard: UInt8,
        stock: [UInt8],
        wrapEnabled: Bool
    ) {
        self.peaksMask = peaksMask
        self.currentCard = currentCard
        self.stock = stock
        self.wrapEnabled = wrapEnabled
    }

    /// Check if won - all peak cards removed
    public var isWon: Bool {
        peaksMask == 0
    }

    /// Check if a peak slot is present
    public func hasCard(at position: Int) -> Bool {
        position >= 0 && position < 28 && (peaksMask & (1 << position)) != 0
    }

    /// Get cards that are exposed (both children removed)
    public var exposedPositions: [Int] {
        var exposed: [Int] = []

        // Bottom row (positions 18-27) are always exposed
        for i in 18..<28 {
            if hasCard(at: i) {
                exposed.append(i)
            }
        }

        // Middle and upper rows: exposed if both children are gone
        for i in 0..<18 {
            if hasCard(at: i) {
                let left = 2 * i + 1
                let right = 2 * i + 2
                if !hasCard(at: left) && !hasCard(at: right) {
                    exposed.append(i)
                }
            }
        }

        return exposed
    }

    /// Get the rank of the current card
    public var currentRank: UInt8 {
        currentCard % 13
    }

    /// Get suit of current card
    public var currentSuit: UInt8 {
        currentCard / 13
    }
}

// MARK: - TriPeaks Solvable Game Conformance

/// Solver conformance for TriPeaks solitaire (R-SOLVER-1.2, R-SOLVER-1.3)
public struct TriPeaksSolvableGame: SolvableGame {
    public typealias Node = TriPeaksSolverNode

    /// Placeholder state - will be replaced with actual TriPeaksState
    public struct GameStatePlaceholder: GameState {
        public var peaks: [Zone]
        public var stock: Zone
        public var current: Zone
        public var faces: [PieceID: CardFace]
        public var options: TriPeaksOptionsPlaceholder

        public init(
            peaks: [Zone], stock: Zone, current: Zone, faces: [PieceID: CardFace],
            options: TriPeaksOptionsPlaceholder
        ) {
            self.peaks = peaks
            self.stock = stock
            self.current = current
            self.faces = faces
            self.options = options
        }
    }

    public typealias State = GameStatePlaceholder

    /// TriPeaks-specific action for the solver
    public enum TriPeaksAction: GameAction, Hashable, Codable {
        case playCard(position: Int)
        case drawFromStock
    }

    public init() {}

    public func rootNode(from state: State) -> Node {
        // Build peaks mask
        var mask: UInt32 = 0

        for (index, zone) in state.peaks.enumerated() where index < 28 {
            if !zone.contents.isEmpty {
                mask |= (1 << index)
            }
        }

        // Current card
        var currentCode: UInt8 = 0
        if let topPiece = state.current.contents.last,
            let face = state.faces[topPiece]
        {
            currentCode = cardCode(from: face)
        }

        // Stock
        var stockCodes: [UInt8] = []
        for piece in state.stock.contents {
            if let face = state.faces[piece] {
                stockCodes.append(cardCode(from: face))
            }
        }

        return Node(
            peaksMask: mask,
            currentCard: currentCode,
            stock: stockCodes,
            wrapEnabled: state.options.wrapEnabled
        )
    }

    public func canonicalHash(_ node: Node) -> UInt64 {
        var hasher = Hasher()

        hasher.combine(Int(node.peaksMask))
        hasher.combine(Int(node.currentCard))

        for card in node.stock {
            hasher.combine(Int(card))
        }

        hasher.combine(node.wrapEnabled)

        let intHash = hasher.finalize()
        return UInt64(bitPattern: Int64(intHash))
    }

    public func isWon(_ node: Node) -> Bool {
        return node.isWon
    }

    public func isDead(_ node: Node) -> Bool {
        if node.isWon { return false }

        let exposed = node.exposedPositions
        let currentRank = node.currentRank

        // Check if any exposed card can be played
        for pos in exposed {
            let cardRank = cardRankAtPosition(pos, node: node)
            if canPlayCard(rank: cardRank, currentRank: currentRank, wrapEnabled: node.wrapEnabled)
            {
                return false
            }
        }

        // Can we draw?
        if !node.stock.isEmpty {
            return false
        }

        return true
    }

    private func cardRankAtPosition(_ position: Int, node: TriPeaksSolverNode) -> UInt8 {
        // Simplified - would need actual card from state
        return UInt8(position % 13)
    }

    private func canPlayCard(rank: UInt8, currentRank: UInt8, wrapEnabled: Bool) -> Bool {
        if wrapEnabled {
            if (currentRank == 12 && rank == 0) || (currentRank == 0 && rank == 12) {
                return true
            }
            let diff = abs(Int(currentRank) - Int(rank))
            return diff == 1
        } else {
            let diff = abs(Int(currentRank) - Int(rank))
            return diff == 1
        }
    }

    public func generateMoves(_ node: Node, into out: inout [SolverMove]) {
        out.removeAll()

        var moves: [(priority: Int, move: SolverMove)] = []

        let exposed = node.exposedPositions
        let currentRank = node.currentRank

        // 1. Play exposed cards that are one rank higher or lower
        for pos in exposed {
            let cardRank = cardRankAtPosition(pos, node: node)

            if canPlayCard(rank: cardRank, currentRank: currentRank, wrapEnabled: node.wrapEnabled)
            {
                let action = TriPeaksAction.playCard(position: pos)
                if let solverMove = makeSolverMove(action) {
                    moves.append((priority: 1, move: solverMove))
                }
            }
        }

        // 2. Draw from stock (lower priority)
        if !node.stock.isEmpty {
            let action = TriPeaksAction.drawFromStock
            if let solverMove = makeSolverMove(action) {
                moves.append((priority: 2, move: solverMove))
            }
        }

        // Sort by priority
        moves.sort { $0.priority < $1.priority }

        for (_, move) in moves {
            out.append(move)
        }
    }

    public func apply(_ move: SolverMove, to node: Node) -> Node {
        var newNode = node

        do {
            let action = try move.decode(as: TriPeaksAction.self)

            switch action {
            case .playCard(let position):
                newNode.peaksMask &= ~(1 << position)

            case .drawFromStock:
                if !newNode.stock.isEmpty {
                    let card = newNode.stock.removeFirst()
                    newNode.currentCard = card
                }
            }
        } catch {
            // Return unchanged node
        }

        return newNode
    }

    public func heuristic(_ node: Node) -> Int {
        var score = 0

        let remainingCards = (0..<28).filter { node.hasCard(at: $0) }.count
        score -= remainingCards * 10

        score += node.exposedPositions.count * 5

        if !node.stock.isEmpty {
            score += 3
        }

        let bottomRowRemaining = (18..<28).filter { node.hasCard(at: $0) }.count
        score += (10 - bottomRowRemaining) * 2

        return score
    }

    // MARK: - Private Helpers

    private func cardCode(from face: CardFace) -> UInt8 {
        guard case let .standard(rank, suit) = face else { return 0 }
        let suitIndex: UInt8
        switch suit {
        case .clubs: suitIndex = 0
        case .diamonds: suitIndex = 1
        case .hearts: suitIndex = 2
        case .spades: suitIndex = 3
        }
        return suitIndex * 13 + UInt8(rank.rawValue - 1)
    }

    private func makeSolverMove(_ action: TriPeaksAction) -> SolverMove? {
        do {
            return try SolverMove(action)
        } catch {
            return nil
        }
    }
}

// MARK: - Placeholder Options

public struct TriPeaksOptionsPlaceholder: Codable, Sendable {
    public var wrapEnabled: Bool

    public init(wrapEnabled: Bool = true) {
        self.wrapEnabled = wrapEnabled
    }
}
