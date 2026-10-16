// Copyright © 2025 Parlor. All rights reserved.

import Foundation
import EngineCore

// MARK: - Klondike Solver Node

/// Compact solver node encoding for Klondike.
/// Encodes: 7 tableau columns, stock+waste state, 4 foundation tops, draw-count/pass state
public struct KlondikeSolverNode: Sendable, Codable, Equatable {
    /// Tableau columns: each is an array of card codes (face-up only for compactness).
    public var tableau: [[UInt8]]  // 7 columns, each card is 0-51
    public var stock: [UInt8]
    public var waste: [UInt8]
    public var foundations: [UInt8?]  // 4 slots
    public var tableauFaceDown: [Int]
    public var drawCount: Int
    public var passes: Int

    public init(
        tableau: [[UInt8]],
        stock: [UInt8],
        waste: [UInt8],
        foundations: [UInt8?],
        tableauFaceDown: [Int],
        drawCount: Int,
        passes: Int
    ) {
        self.tableau = tableau
        self.stock = stock
        self.waste = waste
        self.foundations = foundations
        self.tableauFaceDown = tableauFaceDown
        self.drawCount = drawCount
        self.passes = passes
    }

    public var isWon: Bool {
        for top in foundations {
            guard let t = top, t == 12 else { return false }
        }
        return true
    }

    public var isDead: Bool {
        if stock.isEmpty && waste.isEmpty {
            return true
        }
        return false
    }
}

// MARK: - Klondike Action (placeholder - actual comes from GamesRules)

/// Placeholder Klondike action - will be replaced with actual KlondikeAction
public enum KlondikeActionPlaceholder: GameAction, Hashable, Codable {
    case drawFromStock
    case recycleWaste
    case wasteToTableau(toPile: Int)
    case wasteToFoundation(toFoundation: Int)
    case tableauToTableau(fromPile: Int, card: PieceID, toPile: Int)
    case tableauToFoundation(fromPile: Int, toFoundation: Int)
    case foundationToTableau(fromFoundation: Int, toPile: Int)
}

// MARK: - Klondike Solvable Game

public struct KlondikeSolvableGame: SolvableGame {
    public typealias Node = KlondikeSolverNode
    public typealias State = KlondikeStatePlaceholder

    public init() {}

    public func rootNode(from state: State) -> Node {
        var tableau: [[UInt8]] = []
        var tableauFaceDown: [Int] = []

        for (_, zone) in state.tableau.enumerated() {
            var column: [UInt8] = []
            let pieces = zone.contents
            let faceDownCount = zone.contents.count - zone.faceUp.count

            for piece in pieces {
                if zone.faceUp.contains(piece), let face = state.faces[piece] {
                    column.append(cardCode(from: face))
                }
            }

            tableau.append(column)
            tableauFaceDown.append(faceDownCount)
        }

        var stockCodes: [UInt8] = []
        for piece in state.stock.contents {
            if let face = state.faces[piece] {
                stockCodes.append(cardCode(from: face))
            }
        }

        var wasteCodes: [UInt8] = []
        for piece in state.waste.contents {
            if let face = state.faces[piece] {
                wasteCodes.append(cardCode(from: face))
            }
        }

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
            stock: stockCodes,
            waste: wasteCodes,
            foundations: foundationTops,
            tableauFaceDown: tableauFaceDown,
            drawCount: state.options.drawCount,
            passes: state.passes
        )
    }

    public func canonicalHash(_ node: Node) -> UInt64 {
        var hasher = Hasher()

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

        for card in node.stock { hasher.combine(Int(card)) }
        for card in node.waste { hasher.combine(Int(card)) }

        for top in node.foundations {
            hasher.combine(top.map { Int($0) } ?? 255)
        }

        hasher.combine(node.drawCount)
        hasher.combine(node.passes)

        let intHash = hasher.finalize()
        return UInt64(bitPattern: Int64(intHash))
    }

    public func isWon(_ node: Node) -> Bool { node.isWon }
    public func isDead(_ node: Node) -> Bool { node.isDead }

    public func generateMoves(_ node: Node, into out: inout [SolverMove]) {
        out.removeAll()

        var moves: [(priority: Int, move: SolverMove)] = []

        // 1. Stock draws
        if !node.stock.isEmpty {
            let drawCount = min(node.drawCount, node.stock.count)
            for _ in 0..<drawCount {
                let action = KlondikeActionPlaceholder.drawFromStock
                if let solverMove = makeSolverMove(action) {
                    moves.append((priority: 4, move: solverMove))
                }
            }
        }

        // 2. Waste to foundation
        if let topWaste = node.waste.last {
            for foundationIndex in 0..<4 {
                if canMoveToFoundation(card: topWaste, foundationIndex: foundationIndex, node: node)
                {
                    let action = KlondikeActionPlaceholder.wasteToFoundation(
                        toFoundation: foundationIndex)
                    if let solverMove = makeSolverMove(action) {
                        moves.append((priority: 2, move: solverMove))
                    }
                }
            }
        }

        // 3. Waste to tableau
        if let topWaste = node.waste.last {
            for pileIndex in 0..<7 {
                if canMoveToTableau(card: topWaste, pileIndex: pileIndex, node: node) {
                    let action = KlondikeActionPlaceholder.wasteToTableau(toPile: pileIndex)
                    if let solverMove = makeSolverMove(action) {
                        moves.append((priority: 3, move: solverMove))
                    }
                }
            }
        }

        // 4. Tableau to foundation
        for pileIndex in 0..<7 {
            guard let topCard = node.tableau[pileIndex].last else { continue }
            for foundationIndex in 0..<4 {
                if canMoveToFoundation(card: topCard, foundationIndex: foundationIndex, node: node)
                {
                    let action = KlondikeActionPlaceholder.tableauToFoundation(
                        fromPile: pileIndex, toFoundation: foundationIndex)
                    if let solverMove = makeSolverMove(action) {
                        moves.append((priority: 2, move: solverMove))
                    }
                }
            }
        }

        // 5. Tableau to tableau
        for fromPile in 0..<7 {
            guard !node.tableau[fromPile].isEmpty else { continue }
            let card = node.tableau[fromPile].last!

            for toPile in 0..<7 {
                if fromPile == toPile { continue }
                if canMoveToTableau(card: card, pileIndex: toPile, node: node) {
                    let action = KlondikeActionPlaceholder.tableauToTableau(
                        fromPile: fromPile, card: PieceID(raw: UInt64(card)), toPile: toPile)
                    if let solverMove = makeSolverMove(action) {
                        moves.append((priority: 3, move: solverMove))
                    }
                }
            }
        }

        moves.sort { $0.priority < $1.priority }
        for (_, move) in moves { out.append(move) }
    }

    public func apply(_ move: SolverMove, to node: Node) -> Node {
        var newNode = node

        do {
            let action = try move.decode(as: KlondikeActionPlaceholder.self)

            switch action {
            case .drawFromStock:
                if !newNode.stock.isEmpty {
                    let drawCount = min(newNode.drawCount, newNode.stock.count)
                    for _ in 0..<drawCount where !newNode.stock.isEmpty {
                        let card = newNode.stock.removeFirst()
                        newNode.waste.append(card)
                    }
                }
            case .wasteToTableau(let toPile):
                if let card = newNode.waste.last {
                    newNode.waste.removeLast()
                    newNode.tableau[toPile].append(card)
                }
            case .wasteToFoundation(let toFoundation):
                if let card = newNode.waste.last {
                    newNode.waste.removeLast()
                    newNode.foundations[toFoundation] = card % 13
                }
            case .tableauToTableau(let fromPile, let card, let toPile):
                if let cardIndex = newNode.tableau[fromPile].firstIndex(of: UInt8(card.raw)) {
                    let cardsToMove = Array(newNode.tableau[fromPile][cardIndex...])
                    newNode.tableau[fromPile].removeSubrange(cardIndex...)
                    newNode.tableau[toPile].append(contentsOf: cardsToMove)
                    if newNode.tableauFaceDown[fromPile] > 0 && newNode.tableau[fromPile].isEmpty {
                        newNode.tableauFaceDown[fromPile] = max(
                            0, newNode.tableauFaceDown[fromPile] - 1)
                    }
                }
            case .tableauToFoundation(let fromPile, let toFoundation):
                if let card = newNode.tableau[fromPile].last {
                    newNode.tableau[fromPile].removeLast()
                    newNode.foundations[toFoundation] = card % 13
                    if newNode.tableauFaceDown[fromPile] > 0 && newNode.tableau[fromPile].isEmpty {
                        newNode.tableauFaceDown[fromPile] = max(
                            0, newNode.tableauFaceDown[fromPile] - 1)
                    }
                }
            case .foundationToTableau, .recycleWaste:
                break
            }
        } catch {}

        return newNode
    }

    public func heuristic(_ node: Node) -> Int {
        var score = 0
        for top in node.foundations {
            if let t = top { score += Int(t + 1) }
        }
        for column in node.tableau {
            if column.isEmpty { score += 10 }
        }
        return score
    }

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

    private func makeSolverMove(_ action: KlondikeActionPlaceholder) -> SolverMove? {
        do { return try SolverMove(action) } catch { return nil }
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

    private func canMoveToTableau(card: UInt8, pileIndex: Int, node: Node) -> Bool {
        let rank = card % 13
        let suit = card / 13

        guard !node.tableau[pileIndex].isEmpty else { return rank == 12 }

        let topCard = node.tableau[pileIndex].last!
        let topRank = topCard % 13
        let topSuit = topCard / 13

        let colorMatches = (suit % 2) != (topSuit % 2)
        return rank + 1 == topRank && colorMatches
    }
}

// MARK: - Placeholder Types

public struct KlondikeStatePlaceholder: GameState {
    public var stock: Zone
    public var waste: Zone
    public var tableau: [Zone]
    public var foundations: [Zone]
    public var faces: [PieceID: CardFace]
    public var score: Int
    public var passes: Int
    public var options: KlondikeOptionsPlaceholder

    public init(
        stock: Zone, waste: Zone, tableau: [Zone], foundations: [Zone], faces: [PieceID: CardFace],
        score: Int, passes: Int, options: KlondikeOptionsPlaceholder
    ) {
        self.stock = stock
        self.waste = waste
        self.tableau = tableau
        self.foundations = foundations
        self.faces = faces
        self.score = score
        self.passes = passes
        self.options = options
    }
}

public struct KlondikeOptionsPlaceholder: Codable, Sendable {
    public var drawCount: Int

    public init(drawCount: Int = 1) {
        self.drawCount = drawCount
    }
}
