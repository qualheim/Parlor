// Copyright © 2025 Parlor. All rights reserved.

import Foundation
import EngineCore

// MARK: - Spider Solver Node

/// Compact solver node encoding for Spider solitaire.
/// Encodes: 10 tableau columns, stock remaining, completed runs, suit-count variant
public struct SpiderSolverNode: Sendable, Codable, Equatable {
    /// Tableau columns: arrays of card codes (0-103 for spider-104 deck)
    public var tableau: [[UInt8]]  // 10 columns

    /// Stock: remaining cards to deal (face-down)
    public var stock: [UInt8]

    /// Number of completed runs (8 = win)
    public var completedRuns: Int

    /// Suit count variant: 1, 2, or 4
    public var suitCount: Int

    public init(
        tableau: [[UInt8]],
        stock: [UInt8],
        completedRuns: Int,
        suitCount: Int
    ) {
        self.tableau = tableau
        self.stock = stock
        self.completedRuns = completedRuns
        self.suitCount = suitCount
    }

    /// Check if won - all 8 runs completed
    public var isWon: Bool {
        completedRuns >= 8
    }

    /// Number of empty tableau columns
    public var emptyColumns: Int {
        tableau.filter { $0.isEmpty }.count
    }
}

// MARK: - Spider Solvable Game Conformance

/// Solver conformance for Spider solitaire (R-SOLVER-1.2, R-SOLVER-1.3)
/// Supports 1-suit and 2-suit variants using spider-104 codes
public struct SpiderSolvableGame: SolvableGame {
    public typealias Node = SpiderSolverNode

    /// Placeholder state - will be replaced with actual SpiderState
    public struct GameStatePlaceholder: GameState {
        public var tableau: [Zone]
        public var stock: Zone
        public var faces: [PieceID: CardFace]
        public var completedRuns: Int
        public var suitCount: Int

        public init(
            tableau: [Zone], stock: Zone, faces: [PieceID: CardFace], completedRuns: Int,
            suitCount: Int
        ) {
            self.tableau = tableau
            self.stock = stock
            self.faces = faces
            self.completedRuns = completedRuns
            self.suitCount = suitCount
        }
    }

    public typealias State = GameStatePlaceholder

    /// Spider-specific action for the solver
    public enum SpiderAction: GameAction, Hashable, Codable {
        case tableauToTableau(fromColumn: Int, toColumn: Int, cardCount: Int)
        case dealFromStock
        case collectRun(column: Int)
    }

    public init() {}

    public func rootNode(from state: State) -> Node {
        var tableau: [[UInt8]] = Array(repeating: [], count: 10)

        for (index, zone) in state.tableau.enumerated() where index < 10 {
            var column: [UInt8] = []
            for piece in zone.contents {
                if let face = state.faces[piece] {
                    column.append(spiderCode(from: face, suitCount: state.suitCount))
                }
            }
            tableau[index] = column
        }

        // Stock
        var stockCodes: [UInt8] = []
        for piece in state.stock.contents {
            if let face = state.faces[piece] {
                stockCodes.append(spiderCode(from: face, suitCount: state.suitCount))
            }
        }

        return Node(
            tableau: tableau,
            stock: stockCodes,
            completedRuns: state.completedRuns,
            suitCount: state.suitCount
        )
    }

    public func canonicalHash(_ node: Node) -> UInt64 {
        var hasher = Hasher()

        // Sort tableau columns by stable key
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

        // Stock
        for card in node.stock {
            hasher.combine(Int(card))
        }

        // Game state
        hasher.combine(node.completedRuns)
        hasher.combine(node.suitCount)

        let intHash = hasher.finalize()
        return UInt64(bitPattern: Int64(intHash))
    }

    public func isWon(_ node: Node) -> Bool {
        return node.isWon
    }

    public func isDead(_ node: Node) -> Bool {
        if node.stock.isEmpty && !hasAnyLegalMove(node) {
            return true
        }
        return false
    }

    private func hasAnyLegalMove(_ node: Node) -> Bool {
        // Check if any tableau move is possible
        for (fromIdx, fromCol) in node.tableau.enumerated() {
            if fromCol.isEmpty { continue }

            for (toIdx, toCol) in node.tableau.enumerated() {
                if fromIdx == toIdx { continue }

                // Try single card move
                let card = fromCol.last!
                if canMoveToTableau(card: card, toColumn: toCol, suitCount: node.suitCount) {
                    return true
                }

                // Check for same-suit sequence moves
                if fromCol.count > 1 {
                    let potentialSequence = fromCol.suffix(fromCol.count - 1)
                    if isSameSuitDescending(potentialSequence) {
                        let leadCard = potentialSequence.first!
                        if canMoveToTableau(
                            card: leadCard, toColumn: toCol, suitCount: node.suitCount)
                        {
                            return true
                        }
                    }
                }
            }
        }
        return false
    }

    public func generateMoves(_ node: Node, into out: inout [SolverMove]) {
        out.removeAll()

        var moves: [(priority: Int, move: SolverMove)] = []

        // 1. Auto-collect runs (highest priority - forced/auto moves)
        for colIndex in 0..<10 {
            if let run = findCompletedRun(in: node.tableau[colIndex], suitCount: node.suitCount) {
                if run.count == 13 {
                    let action = SpiderAction.collectRun(column: colIndex)
                    if let solverMove = makeSolverMove(action) {
                        moves.append((priority: 1, move: solverMove))
                    }
                }
            }
        }

        // 2. Stock deal
        if !node.stock.isEmpty && !node.tableau.contains(where: { $0.isEmpty }) {
            let action = SpiderAction.dealFromStock
            if let solverMove = makeSolverMove(action) {
                moves.append((priority: 4, move: solverMove))
            }
        }

        // 3. Tableau to tableau moves
        for fromColumn in 0..<10 {
            guard !node.tableau[fromColumn].isEmpty else { continue }

            for toColumn in 0..<10 {
                if fromColumn == toColumn { continue }

                // Try single card moves
                let card = node.tableau[fromColumn].last!
                if canMoveToTableau(
                    card: card, toColumn: node.tableau[toColumn], suitCount: node.suitCount)
                {
                    let action = SpiderAction.tableauToTableau(
                        fromColumn: fromColumn, toColumn: toColumn, cardCount: 1)
                    if let solverMove = makeSolverMove(action) {
                        moves.append((priority: 3, move: solverMove))
                    }
                }

                // Try same-suit sequence moves
                if node.tableau[fromColumn].count >= 2 {
                    let col = node.tableau[fromColumn]
                    for seqStart in 0..<(col.count - 1) {
                        let sequence = col[seqStart...]
                        if isSameSuitDescending(sequence)
                            && canMoveToTableau(
                                card: sequence.first!, toColumn: node.tableau[toColumn],
                                suitCount: node.suitCount)
                        {
                            let action = SpiderAction.tableauToTableau(
                                fromColumn: fromColumn, toColumn: toColumn,
                                cardCount: sequence.count)
                            if let solverMove = makeSolverMove(action) {
                                moves.append((priority: 2, move: solverMove))
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
            let action = try move.decode(as: SpiderAction.self)

            switch action {
            case .collectRun(let column):
                if newNode.tableau[column].count >= 13 {
                    let run = newNode.tableau[column].suffix(13)
                    if isSameSuitDescending(run) && run.first! % 13 == 12 {
                        newNode.tableau[column].removeLast(13)
                        newNode.completedRuns += 1
                    }
                }

            case .dealFromStock:
                for i in 0..<10 {
                    if !newNode.stock.isEmpty && !newNode.tableau[i].isEmpty {
                        let card = newNode.stock.removeFirst()
                        newNode.tableau[i].append(card)
                    }
                }

            case .tableauToTableau(let fromColumn, let toColumn, let cardCount):
                guard cardCount <= newNode.tableau[fromColumn].count else { break }
                let cards = newNode.tableau[fromColumn].suffix(cardCount)
                newNode.tableau[fromColumn].removeLast(cardCount)
                newNode.tableau[toColumn].append(contentsOf: cards)
            }
        } catch {
            // Return unchanged node
        }

        return newNode
    }

    public func heuristic(_ node: Node) -> Int {
        var score = 0

        // Completed runs are very valuable
        score += node.completedRuns * 100

        // Empty columns provide mobility
        score += node.emptyColumns * 20

        // Cards in descending sequences
        for column in node.tableau {
            score += countDescendingSequenceValue(column, suitCount: node.suitCount)
        }

        // Stock cards remaining
        score -= node.stock.count

        return score
    }

    // MARK: - Private Helpers

    private func spiderCode(from face: CardFace, suitCount: Int) -> UInt8 {
        guard case let .standard(rank, suit) = face else { return 0 }

        let reducedSuit: UInt8
        switch suitCount {
        case 1:
            reducedSuit = 0
        case 2:
            reducedSuit = (suit == .clubs || suit == .diamonds) ? 0 : 1
        default:
            switch suit {
            case .clubs: reducedSuit = 0
            case .diamonds: reducedSuit = 1
            case .hearts: reducedSuit = 2
            case .spades: reducedSuit = 3
            }
        }

        return reducedSuit * 13 + UInt8(rank.rawValue - 1)
    }

    private func makeSolverMove(_ action: SpiderAction) -> SolverMove? {
        do {
            return try SolverMove(action)
        } catch {
            return nil
        }
    }

    private func canMoveToTableau(card: UInt8, toColumn: [UInt8], suitCount: Int) -> Bool {
        let rank = card % 13

        if toColumn.isEmpty {
            return rank == 12
        }

        let topCard = toColumn.last!
        let topRank = topCard % 13

        // Can place any card one rank higher, regardless of suit
        return rank == topRank + 1
    }

    private func isSameSuitDescending(_ cards: ArraySlice<UInt8>) -> Bool {
        guard cards.count >= 2 else { return true }

        for i in 0..<(cards.count - 1) {
            let upper = cards[i]
            let lower = cards[i + 1]

            if upper / 13 != lower / 13 {
                return false
            }
            if upper % 13 != (lower % 13) + 1 {
                return false
            }
        }

        return true
    }

    private func findCompletedRun(in column: [UInt8], suitCount: Int) -> [UInt8]? {
        guard column.count >= 13 else { return nil }

        let potentialRun = column.suffix(13)
        if isSameSuitDescending(potentialRun) && potentialRun.first! % 13 == 12 {
            return Array(potentialRun)
        }

        return nil
    }

    private func countDescendingSequenceValue(_ column: [UInt8], suitCount: Int) -> Int {
        var maxSequence = 0
        var currentSequence = 1

        for i in 1..<column.count {
            let upper = column[i - 1]
            let lower = column[i]

            if upper / 13 == lower / 13 && upper % 13 == (lower % 13) + 1 {
                currentSequence += 1
            } else {
                maxSequence = max(maxSequence, currentSequence)
                currentSequence = 1
            }
        }

        return max(maxSequence, currentSequence)
    }
}
