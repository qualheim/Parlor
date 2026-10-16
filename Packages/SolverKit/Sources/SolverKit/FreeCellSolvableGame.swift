// Copyright © 2025 Parlor. All rights reserved.

import Foundation
import EngineCore

// MARK: - FreeCell Solver Node

/// Compact solver node encoding for FreeCell.
/// Encodes: 8 tableau columns, 4 free-cell slots, 4 foundation tops
public struct FreeCellSolverNode: Sendable, Codable, Equatable {
    /// Tableau columns: arrays of card codes (0-51), all face-up
    public var tableau: [[UInt8]]  // 8 columns

    /// Free cell contents: card code or 255 for empty
    public var freeCells: [UInt8]  // 4 slots, 255 = empty

    /// Foundation tops: rank per suit (0-12 for A-K), nil if empty
    public var foundations: [UInt8?]  // 4 slots

    public init(
        tableau: [[UInt8]],
        freeCells: [UInt8],
        foundations: [UInt8?]
    ) {
        self.tableau = tableau
        self.freeCells = freeCells
        self.foundations = foundations
    }

    /// Check if won - all cards in foundations (all Kings)
    public var isWon: Bool {
        for top in foundations {
            guard let t = top, t == 12 else { return false }
        }
        return true
    }

    /// Number of empty free cells
    public var emptyFreeCells: Int {
        freeCells.filter { $0 == 255 }.count
    }

    /// Number of empty tableau columns
    public var emptyTableauColumns: Int {
        tableau.filter { $0.isEmpty }.count
    }

    /// Calculate supermove capacity
    /// N ≤ (freeCells + 1) × 2^(emptyColumns)
    public var supermoveCapacity: Int {
        let emptyCols = emptyTableauColumns
        return (emptyFreeCells + 1) * (1 << emptyCols)
    }
}

// MARK: - FreeCell Solvable Game Conformance

/// Solver conformance for FreeCell solitaire (R-SOLVER-1.2, R-SOLVER-1.3)
public struct FreeCellSolvableGame: SolvableGame {
    public typealias Node = FreeCellSolverNode

    /// Placeholder state - will be replaced with actual FreeCellState
    public struct GameStatePlaceholder: GameState {
        public var tableau: [Zone]
        public var cells: [Zone]
        public var foundations: [Zone]
        public var faces: [PieceID: CardFace]

        public init(tableau: [Zone], cells: [Zone], foundations: [Zone], faces: [PieceID: CardFace])
        {
            self.tableau = tableau
            self.cells = cells
            self.foundations = foundations
            self.faces = faces
        }
    }

    public typealias State = GameStatePlaceholder

    public init() {}

    public func rootNode(from state: State) -> Node {
        var tableau: [[UInt8]] = Array(repeating: [], count: 8)

        for (index, zone) in state.tableau.enumerated() where index < 8 {
            var column: [UInt8] = []
            for piece in zone.contents {
                if let face = state.faces[piece] {
                    column.append(cardCode(from: face))
                }
            }
            tableau[index] = column
        }

        // Free cells
        var freeCellContents: [UInt8] = []
        for cell in state.cells {
            if let piece = cell.contents.first,
                let face = state.faces[piece]
            {
                freeCellContents.append(cardCode(from: face))
            } else {
                freeCellContents.append(255)  // Empty
            }
        }
        while freeCellContents.count < 4 {
            freeCellContents.append(255)
        }

        // Foundations
        var foundationTops: [UInt8?] = []
        for foundation in state.foundations {
            if let topPiece = foundation.contents.last,
                let face = state.faces[topPiece]
            {
                foundationTops.append(cardCode(from: face) % 13)
            } else {
                foundationTops.append(nil)
            }
        }

        return Node(
            tableau: tableau,
            freeCells: Array(freeCellContents.prefix(4)),
            foundations: foundationTops
        )
    }

    public func canonicalHash(_ node: Node) -> UInt64 {
        var hasher = Hasher()

        // Sort tableau columns by stable key for canonical ordering
        let sortedTableau = node.tableau.enumerated().sorted { a, b in
            let keyA = (a.offset, a.element.first ?? 255, a.element.count)
            let keyB = (b.offset, b.element.first ?? 255, b.element.count)
            return keyA < keyB
        }

        for (index, column) in sortedTableau {
            hasher.combine(index)
            for card in column {
                hasher.combine(Int(card))
            }
        }

        // Free cells in fixed order
        for cell in node.freeCells {
            hasher.combine(Int(cell))
        }

        // Foundations in fixed suit order
        for top in node.foundations {
            hasher.combine(top.map { Int($0) } ?? 255)
        }

        let intHash = hasher.finalize()
        return UInt64(bitPattern: Int64(intHash))
    }

    public func isWon(_ node: Node) -> Bool {
        return node.isWon
    }

    public func isDead(_ node: Node) -> Bool {
        let hasMoves = hasAnyLegalMove(node)
        return !hasMoves && !node.isWon
    }

    private func hasAnyLegalMove(_ node: Node) -> Bool {
        // Free cell available?
        if node.emptyFreeCells > 0 {
            return true
        }

        // Can move to foundation?
        for column in node.tableau {
            if let top = column.last {
                for (fi, _) in node.foundations.enumerated() {
                    if canMoveToFoundation(card: top, foundationIndex: fi, node: node) {
                        return true
                    }
                }
            }
        }

        // Can move tableau to tableau?
        for (fromIdx, fromCol) in node.tableau.enumerated() {
            if fromCol.isEmpty { continue }
            let card = fromCol.last!
            for (toIdx, toCol) in node.tableau.enumerated() {
                if fromIdx == toIdx { continue }
                if canMoveToTableau(card: card, toColumn: toCol, node: node) {
                    return true
                }
            }
        }

        return false
    }

    public func generateMoves(_ node: Node, into out: inout [SolverMove]) {
        out.removeAll()

        var moves: [(priority: Int, move: SolverMove)] = []

        // 1. Foundation moves (highest priority)
        // From tableau to foundation
        for pileIndex in 0..<8 {
            guard let topCard = node.tableau[pileIndex].last else { continue }
            for foundationIndex in 0..<4 {
                if canMoveToFoundation(card: topCard, foundationIndex: foundationIndex, node: node)
                {
                    let action = FreeCellAction.tableauToFoundation(
                        fromPile: pileIndex, toFoundation: foundationIndex)
                    if let solverMove = makeSolverMove(action) {
                        moves.append((priority: 1, move: solverMove))
                    }
                }
            }
        }

        // From free cell to foundation
        for (cellIndex, cellCard) in node.freeCells.enumerated() {
            guard cellCard != 255 else { continue }
            for foundationIndex in 0..<4 {
                if canMoveToFoundation(card: cellCard, foundationIndex: foundationIndex, node: node)
                {
                    let action = FreeCellAction.freeCellToFoundation(
                        fromCell: cellIndex, toFoundation: foundationIndex)
                    if let solverMove = makeSolverMove(action) {
                        moves.append((priority: 1, move: solverMove))
                    }
                }
            }
        }

        // 2. Free cell moves (lower priority - reversible)
        // Tableau to free cell
        for pileIndex in 0..<8 {
            guard !node.tableau[pileIndex].isEmpty else { continue }
            if node.emptyFreeCells > 0 {
                let action = FreeCellAction.tableauToFreeCell(
                    fromPile: pileIndex, toCell: node.freeCells.firstIndex(of: 255)!)
                if let solverMove = makeSolverMove(action) {
                    moves.append((priority: 4, move: solverMove))
                }
            }
        }

        // 3. Tableau to tableau moves
        // Single card moves
        for fromPile in 0..<8 {
            guard !node.tableau[fromPile].isEmpty else { continue }

            // Check supermove capacity
            let maxCards = node.supermoveCapacity

            for toPile in 0..<8 {
                if fromPile == toPile { continue }

                let toColumn = node.tableau[toPile]

                // Determine how many cards we can move
                let canMoveCount = min(maxCards, node.tableau[fromPile].count)

                for moveCount in 1...canMoveCount {
                    let cardsToMove = Array(node.tableau[fromPile].suffix(moveCount))

                    // Validate all cards can move together (same suit, descending)
                    if moveCount > 1 {
                        var valid = true
                        for i in 0..<(cardsToMove.count - 1) {
                            let upper = cardsToMove[i]
                            let lower = cardsToMove[i + 1]
                            if upper / 13 != lower / 13 || upper % 13 != (lower % 13) + 1 {
                                valid = false
                                break
                            }
                        }
                        if !valid { continue }
                    }

                    // Check destination
                    let leadCard = cardsToMove.first!
                    if canMoveToTableau(card: leadCard, toColumn: toColumn, node: node) {
                        // For simplicity, only add single-card moves in this version
                        if moveCount == 1 {
                            let action = FreeCellAction.tableauToTableau(
                                fromPile: fromPile, toPile: toPile, cardCount: 1)
                            if let solverMove = makeSolverMove(action) {
                                moves.append((priority: 3, move: solverMove))
                            }
                        }
                    }
                }
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
            let action = try move.decode(as: FreeCellAction.self)

            switch action {
            case .tableauToFoundation(let fromPile, let toFoundation):
                if let card = newNode.tableau[fromPile].last {
                    newNode.tableau[fromPile].removeLast()
                    newNode.foundations[toFoundation] = card % 13
                }

            case .tableauToFreeCell(let fromPile, let toCell):
                if let card = newNode.tableau[fromPile].last {
                    newNode.tableau[fromPile].removeLast()
                    newNode.freeCells[toCell] = card
                }

            case .tableauToTableau(let fromPile, let toPile, let cardCount):
                if cardCount == 1, let card = newNode.tableau[fromPile].last {
                    newNode.tableau[fromPile].removeLast()
                    newNode.tableau[toPile].append(card)
                }

            case .freeCellToFoundation(let fromCell, let toFoundation):
                let card = newNode.freeCells[fromCell]
                if card != 255 {
                    newNode.freeCells[fromCell] = 255
                    newNode.foundations[toFoundation] = card % 13
                }

            case .freeCellToTableau(let fromCell, let toPile):
                let card = newNode.freeCells[fromCell]
                if card != 255 {
                    newNode.freeCells[fromCell] = 255
                    newNode.tableau[toPile].append(card)
                }

            case .freeCellToFreeCell(let fromCell, let toCell):
                let card = newNode.freeCells[fromCell]
                if card != 255 {
                    newNode.freeCells[fromCell] = newNode.freeCells[toCell]
                    newNode.freeCells[toCell] = card
                }
            }
        } catch {
            // Return unchanged node on decode failure
        }

        return newNode
    }

    public func heuristic(_ node: Node) -> Int {
        var score = 0

        // Cards in foundations
        for top in node.foundations {
            if let t = top {
                score += Int(t + 1)
            }
        }

        // Bonus for empty columns (mobility)
        score += node.emptyTableauColumns * 10

        // Bonus for empty free cells
        score += node.emptyFreeCells * 5

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

    private func makeSolverMove(_ action: FreeCellAction) -> SolverMove? {
        do {
            return try SolverMove(action)
        } catch {
            return nil
        }
    }

    private func canMoveToFoundation(card: UInt8, foundationIndex: Int, node: Node) -> Bool {
        let rank = card % 13
        let suit = card / 13

        guard suit == UInt8(foundationIndex) else { return false }

        if let top = node.foundations[foundationIndex] {
            return rank == top + 1
        } else {
            return rank == 0
        }
    }

    private func canMoveToTableau(card: UInt8, toColumn: [UInt8], node: Node) -> Bool {
        let rank = card % 13
        let suit = card / 13

        guard !toColumn.isEmpty else {
            // Empty column accepts any single card
            return true
        }

        let topCard = toColumn.last!
        let topRank = topCard % 13
        let topSuit = topCard / 13

        // Must be one lower and alternating color
        let colorMatches = (suit % 2) != (topSuit % 2)
        return rank + 1 == topRank && colorMatches
    }
}

// MARK: - FreeCell Action

/// FreeCell actions for the solver
public enum FreeCellAction: GameAction, Hashable, Codable {
    case tableauToFoundation(fromPile: Int, toFoundation: Int)
    case tableauToFreeCell(fromPile: Int, toCell: Int)
    case tableauToTableau(fromPile: Int, toPile: Int, cardCount: Int)
    case freeCellToFoundation(fromCell: Int, toFoundation: Int)
    case freeCellToTableau(fromCell: Int, toPile: Int)
    case freeCellToFreeCell(fromCell: Int, toCell: Int)
}
