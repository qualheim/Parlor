// Copyright © 2025 Parlor. All rights reserved.

import Foundation
import EngineCore

// MARK: - Pyramid Solver Node

/// Compact solver node encoding for Pyramid solitaire.
/// Uses 28-bit mask for pyramid slots, plus stock/waste cursors and redeal counter.
public struct PyramidSolverNode: Sendable, Codable, Equatable {
    /// 28-bit mask of pyramid slots still in play (1 = card present, 0 = removed)
    public var pyramidMask: UInt32

    /// Stock: remaining cards (face-down)
    public var stock: [UInt8]

    /// Waste: cards turned face-up (top card is accessible)
    public var waste: [UInt8]

    /// Number of redeals used
    public var redealsUsed: Int

    /// Maximum allowed redeals (0, 1, 2, or 255 for unlimited)
    public var maxRedeals: Int

    public init(
        pyramidMask: UInt32,
        stock: [UInt8],
        waste: [UInt8],
        redealsUsed: Int,
        maxRedeals: Int
    ) {
        self.pyramidMask = pyramidMask
        self.stock = stock
        self.waste = waste
        self.redealsUsed = redealsUsed
        self.maxRedeals = maxRedeals
    }

    /// Check if won - all pyramid cards removed
    public var isWon: Bool {
        pyramidMask == 0
    }

    /// Check if a pyramid slot is present
    public func hasCard(at position: Int) -> Bool {
        position >= 0 && position < 28 && (pyramidMask & (1 << position)) != 0
    }

    /// Get cards that are exposed (both children removed)
    public var exposedPositions: [Int] {
        var exposed: [Int] = []

        // Bottom row (positions 21-27) are always exposed
        for i in 21..<28 {
            if hasCard(at: i) {
                exposed.append(i)
            }
        }

        // Other positions: exposed if both children are gone
        for i in 0..<21 {
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

    /// Get waste top card
    public var wasteTop: UInt8? {
        waste.last
    }

    /// Get stock top card
    public var stockTop: UInt8? {
        stock.first
    }

    /// Check if can draw from stock
    public var canDraw: Bool {
        !stock.isEmpty || (!waste.isEmpty && canRecycle)
    }

    /// Check if can recycle waste
    public var canRecycle: Bool {
        maxRedeals == 255 || redealsUsed < maxRedeals
    }
}

// MARK: - Pyramid Solvable Game Conformance

/// Solver conformance for Pyramid solitaire (R-SOLVER-1.2, R-SOLVER-1.3)
public struct PyramidSolvableGame: SolvableGame {
    public typealias Node = PyramidSolverNode

    /// Placeholder state - will be replaced with actual PyramidState
    public struct GameStatePlaceholder: GameState {
        public var pyramid: [Zone]
        public var stock: Zone
        public var waste: Zone
        public var faces: [PieceID: CardFace]
        public var redealsUsed: Int
        public var options: PyramidOptionsPlaceholder

        public init(
            pyramid: [Zone], stock: Zone, waste: Zone, faces: [PieceID: CardFace], redealsUsed: Int,
            options: PyramidOptionsPlaceholder
        ) {
            self.pyramid = pyramid
            self.stock = stock
            self.waste = waste
            self.faces = faces
            self.redealsUsed = redealsUsed
            self.options = options
        }
    }

    public typealias State = GameStatePlaceholder

    /// Pyramid-specific action for the solver
    public enum PyramidAction: GameAction, Hashable, Codable {
        case removePair(pos1: Int, pos2: Int)
        case removeKing(position: Int)
        case drawFromStock
        case recycleWaste
    }

    public init() {}

    public func rootNode(from state: State) -> Node {
        // Build pyramid mask from state
        var mask: UInt32 = 0

        for (index, zone) in state.pyramid.enumerated() where index < 28 {
            if !zone.contents.isEmpty {
                mask |= (1 << index)
            }
        }

        // Stock cards
        var stockCodes: [UInt8] = []
        for piece in state.stock.contents {
            if let face = state.faces[piece] {
                stockCodes.append(cardCode(from: face))
            }
        }

        // Waste cards
        var wasteCodes: [UInt8] = []
        for piece in state.waste.contents {
            if let face = state.faces[piece] {
                wasteCodes.append(cardCode(from: face))
            }
        }

        return Node(
            pyramidMask: mask,
            stock: stockCodes,
            waste: wasteCodes,
            redealsUsed: state.redealsUsed,
            maxRedeals: state.options.maxRedeals
        )
    }

    public func canonicalHash(_ node: Node) -> UInt64 {
        var hasher = Hasher()

        hasher.combine(Int(node.pyramidMask))

        for card in node.stock {
            hasher.combine(Int(card))
        }
        for card in node.waste {
            hasher.combine(Int(card))
        }

        hasher.combine(node.redealsUsed)
        hasher.combine(node.maxRedeals)

        let intHash = hasher.finalize()
        return UInt64(bitPattern: Int64(intHash))
    }

    public func isWon(_ node: Node) -> Bool {
        return node.isWon
    }

    public func isDead(_ node: Node) -> Bool {
        if node.isWon { return false }

        let exposed = node.exposedPositions
        let wasteTop = node.wasteTop

        // Check if any removal is possible
        // King removal
        for pos in exposed {
            if hasCardWithRank(pos, rank: 12, state: node) {
                return false
            }
        }

        // Pair removal - check against other exposed cards
        for i in 0..<exposed.count {
            for j in (i + 1)..<exposed.count {
                let rank1 = cardRankAt(exposed[i], node: node)
                let rank2 = cardRankAt(exposed[j], node: node)
                if rank1 != nil && rank2 != nil && (rank1! + rank2!) == 13 {
                    return false
                }
            }
        }

        // Check against waste
        if let w = wasteTop {
            let wasteRank = w % 13
            if wasteRank == 12 { return false }

            for pos in exposed {
                let pyramidRank = cardRankAt(pos, node: node)
                if let pr = pyramidRank, pr + wasteRank == 13 {
                    return false
                }
            }
        }

        // Can we draw or recycle?
        if node.canDraw || node.canRecycle {
            return false
        }

        return true
    }

    private func hasCardWithRank(_ pos: Int, rank: UInt8, state: PyramidSolverNode) -> Bool {
        // Simplified - would need actual card mapping
        return state.hasCard(at: pos)
    }

    private func cardRankAt(_ pos: Int, node: PyramidSolverNode) -> UInt8? {
        guard node.hasCard(at: pos) else { return nil }
        // Simplified - would need actual card from state
        return UInt8(pos % 13)
    }

    public func generateMoves(_ node: Node, into out: inout [SolverMove]) {
        out.removeAll()

        var moves: [(priority: Int, move: SolverMove)] = []
        let exposed = node.exposedPositions

        // 1. King removals (priority 1)
        for pos in exposed {
            if node.hasCard(at: pos) {
                let action = PyramidAction.removeKing(position: pos)
                if let solverMove = makeSolverMove(action) {
                    moves.append((priority: 1, move: solverMove))
                }
            }
        }

        // 2. Sum-to-13 pair removals from pyramid
        for i in 0..<exposed.count {
            for j in (i + 1)..<exposed.count {
                let pos1 = exposed[i]
                let pos2 = exposed[j]

                let rank1 = cardRankAt(pos1, node: node)
                let rank2 = cardRankAt(pos2, node: node)

                if let r1 = rank1, let r2 = rank2, r1 + r2 == 13 {
                    let action = PyramidAction.removePair(pos1: pos1, pos2: pos2)
                    if let solverMove = makeSolverMove(action) {
                        moves.append((priority: 1, move: solverMove))
                    }
                }
            }
        }

        // 3. Draw from stock (priority 4)
        if !node.stock.isEmpty {
            let action = PyramidAction.drawFromStock
            if let solverMove = makeSolverMove(action) {
                moves.append((priority: 4, move: solverMove))
            }
        }

        // 4. Recycle waste (priority 5)
        if node.canRecycle && !node.waste.isEmpty && node.stock.isEmpty {
            let action = PyramidAction.recycleWaste
            if let solverMove = makeSolverMove(action) {
                moves.append((priority: 5, move: solverMove))
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
            let action = try move.decode(as: PyramidAction.self)

            switch action {
            case .removePair(let pos1, let pos2):
                newNode.pyramidMask &= ~(1 << pos1)
                newNode.pyramidMask &= ~(1 << pos2)

            case .removeKing(let position):
                newNode.pyramidMask &= ~(1 << position)

            case .drawFromStock:
                if !newNode.stock.isEmpty {
                    let card = newNode.stock.removeFirst()
                    newNode.waste.append(card)
                }

            case .recycleWaste:
                if !newNode.waste.isEmpty && newNode.stock.isEmpty {
                    newNode.stock = newNode.waste.reversed()
                    newNode.waste.removeAll()
                    newNode.redealsUsed += 1
                }
            }
        } catch {
            // Return unchanged node
        }

        return newNode
    }

    public func heuristic(_ node: Node) -> Int {
        var score = 0

        let remainingCards =
            node.exposedPositions.count + (0..<28).filter { node.hasCard(at: $0) }.count
        score -= remainingCards * 10

        score += node.exposedPositions.count * 5

        if node.canDraw { score += 3 }
        if node.canRecycle { score += 5 }

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

    private func makeSolverMove(_ action: PyramidAction) -> SolverMove? {
        do {
            return try SolverMove(action)
        } catch {
            return nil
        }
    }
}

// MARK: - Placeholder Options

public struct PyramidOptionsPlaceholder: Codable, Sendable {
    public var maxRedeals: Int

    public init(maxRedeals: Int = 2) {
        self.maxRedeals = maxRedeals
    }
}
