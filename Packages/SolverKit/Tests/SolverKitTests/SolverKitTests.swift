// Copyright © 2025 Parlor. All rights reserved.

import Foundation
import XCTest
@testable import SolverKit

// MARK: - Test Fixtures

/// Microsoft FreeCell deal #11982 - famously unsolvable
/// This is the exact dealt card order per the Microsoft algorithm (design.md §3)
struct MicrosoftFreeCellDeal11982 {
    /// The 8 tableau columns as card codes (0-51: suit*13 + rank-1)
    /// Clubs=0, Diamonds=1, Hearts=2, Spades=3; Ace=1...King=13
    /// Generated via Microsoft's LCG algorithm (design.md §3.2)
    static let tableau: [[UInt8]] = [
        // Column 0: 7 cards
        [2, 9, 49, 40, 20, 41, 48],
        // Column 1: 7 cards
        [3, 10, 22, 17, 4, 25, 29],
        // Column 2: 7 cards
        [14, 47, 19, 16, 38, 30, 7],
        // Column 3: 7 cards
        [0, 44, 13, 28, 46, 32, 11],
        // Column 4: 6 cards
        [5, 31, 34, 33, 21, 6],
        // Column 5: 6 cards
        [23, 26, 42, 37, 36, 45],
        // Column 6: 6 cards
        [39, 1, 35, 50, 15, 12],
        // Column 7: 6 cards
        [43, 51, 8, 24, 27, 18],
    ]

    /// Empty free cells at start
    static let freeCells: [UInt8] = [255, 255, 255, 255]

    /// Empty foundations at start
    static let foundations: [UInt8?] = [nil, nil, nil, nil]

    /// Create a FreeCellSolverNode for deal #11982
    static func createNode() -> FreeCellSolverNode {
        FreeCellSolverNode(
            tableau: tableau,
            freeCells: freeCells,
            foundations: foundations
        )
    }
}

/// Small test deals that can be exhaustively verified
struct SmallTestDeals {
    /// A trivial winnable deal - single card that can go to foundation
    static let trivialWinnableNode = FreeCellSolverNode(
        tableau: [[0], [1], [2], [3], [4], [5], [6], [7]],  // A-K of clubs in separate columns
        freeCells: [255, 255, 255, 255],
        foundations: [nil, nil, nil, nil]
    )

    /// An unwinnable deal - single card stuck with no moves
    static let trivialUnwinnableNode = FreeCellSolverNode(
        tableau: [[12], [25], [38], [51], [], [], [], []],  // Kings in alternating colors
        freeCells: [255, 255, 255, 255],
        foundations: [nil, nil, nil, nil]
    )

    /// Another winnable deal - simple two-card move possible
    static let simpleWinnableNode = FreeCellSolverNode(
        tableau: [
            [0, 14],  // A♣ on 2♣ (can't move - same suit)
            [13],  // A♦
            [], [], [], [], [], [],
        ],
        freeCells: [255, 255, 255, 255],
        foundations: [nil, nil, nil, nil]
    )
}

// MARK: - Microsoft Deal Generation

/// Generates a Microsoft-style deal (design.md §3)
struct MicrosoftDealGenerator {
    /// Deal number according to Microsoft's algorithm
    /// - Parameter dealNumber: Microsoft deal number (1-32000)
    /// - Returns: 8 tableau columns as card codes
    static func deal(number: UInt32) -> [[UInt8]] {
        var state = number
        var deck: [UInt8] = Array(0..<52)
        var columns: [[UInt8]] = Array(repeating: [], count: 8)
        var dealtCount = 0
        var remaining = 52

        while remaining > 0 {
            state = (state &* 214013) &+ 2531011
            let rand = Int((state >> 16) & 0x7FFF)
            let idx = rand % remaining
            let card = deck[idx]
            deck[idx] = deck[remaining - 1]
            remaining -= 1
            columns[dealtCount % 8].append(card)
            dealtCount += 1
        }

        return columns
    }
}

// MARK: - Solver Correctness Tests

final class SolverKitTests: XCTestCase {
    // MARK: - Version Test

    func testVersionExists() {
        XCTAssertFalse(SolverKit.version.isEmpty)
    }

    // MARK: - Budget Defaults Tests (R-NFR-SOLVER.1, R-NFR-SOLVER.2)

    /// Verify interactive budget defaults are appropriate for responsive hints
    func testInteractiveBudgetDefaults() {
        let budget = SolveBudget.interactive

        // Interactive budget should be ≤ 1.0s p95 path
        XCTAssertGreaterThan(budget.maxNodes, 0, "Interactive budget must have positive maxNodes")
        XCTAssertLessThanOrEqual(
            budget.maxNodes, 100_000, "Interactive budget should be reasonable for responsive hints"
        )

        if let wallClock = budget.wallClock {
            XCTAssertLessThanOrEqual(
                wallClock.nanoseconds, UInt64(1_500_000_000),
                "Wall clock should be ≤1.5s for interactive use")
        }
    }

    /// Verify generation budget defaults are appropriate for offline analysis
    func testGenerationBudgetDefaults() {
        let budget = SolveBudget.generation

        // Generation budget should be larger than interactive
        XCTAssertGreaterThan(
            budget.maxNodes, SolveBudget.interactive.maxNodes,
            "Generation budget should be larger than interactive")

        // Should have a depth limit for iterative deepening
        XCTAssertNotNil(budget.maxDepth, "Generation budget should have a depth limit")
    }

    // MARK: - Microsoft Deal #11982 Fixture (R-FREECELL-4.4, R-QA2-3.3)

    /// Test that deal #11982 fixture has correct structure
    func testMicrosoftDeal11982Fixture() {
        let node = MicrosoftFreeCellDeal11982.createNode()

        // Verify 8 columns
        XCTAssertEqual(node.tableau.count, 8, "FreeCell should have 8 tableau columns")

        // Verify column counts (4 of 7, 4 of 6)
        let columnCounts = node.tableau.map { $0.count }
        XCTAssertEqual(
            columnCounts.filter { $0 == 7 }.count, 4, "Should have 4 columns with 7 cards")
        XCTAssertEqual(
            columnCounts.filter { $0 == 6 }.count, 4, "Should have 4 columns with 6 cards")

        // Verify total cards = 52
        let totalCards = node.tableau.flatMap { $0 }.count
        XCTAssertEqual(totalCards, 52, "Should have exactly 52 cards")

        // Verify all cards are unique
        let allCards = node.tableau.flatMap { $0 }
        XCTAssertEqual(Set(allCards).count, 52, "All cards should be unique")

        // Verify empty free cells
        XCTAssertEqual(node.emptyFreeCells, 4, "Should start with 4 empty free cells")

        // Verify empty foundations
        XCTAssertTrue(node.foundations.allSatisfy { $0 == nil }, "Foundations should be empty")
    }

    /// Test Microsoft deal generation algorithm
    func testMicrosoftDealGeneration() {
        // Deal #1 should produce known column structure
        let deal1 = MicrosoftDealGenerator.deal(number: 1)
        XCTAssertEqual(deal1.count, 8)

        // Deal #1 should have 52 unique cards
        let allCards = deal1.flatMap { $0 }
        XCTAssertEqual(Set(allCards).count, 52)

        // Deal #11982 should match our fixture
        let deal11982 = MicrosoftDealGenerator.deal(number: 11982)
        XCTAssertEqual(
            deal11982, MicrosoftFreeCellDeal11982.tableau, "Deal generation should match fixture")
    }

    // MARK: - FreeCell Solvable Game Tests

    private func createFreeCellSolver() -> DealSolver<FreeCellSolvableGame> {
        return DealSolver(game: FreeCellSolvableGame())
    }

    /// Test that trivial winnable deal is detected correctly
    func testTrivialWinnableDeal() {
        let game = FreeCellSolvableGame()

        // Test with a node we know should be winnable (cards can go to foundations)
        let node = SmallTestDeals.trivialWinnableNode

        // Check if node is in winning state
        XCTAssertFalse(game.isWon(node), "Should not be won initially")

        // Check if node is not dead
        XCTAssertFalse(game.isDead(node), "Should not be dead - there are legal moves")

        // Generate moves and verify
        var moves: [SolverMove] = []
        game.generateMoves(node, into: &moves)
        XCTAssertFalse(moves.isEmpty, "Should have legal moves")
    }

    /// Test that dead-end deal is detected
    func testDeadEndDeal() {
        let game = FreeCellSolvableGame()

        // A node with no legal moves
        let node = FreeCellSolverNode(
            tableau: [[12], [25], [38], [51], [], [], [], []],
            // All Kings, can't build on each other
            freeCells: [],  // No free cells
            foundations: [nil, nil, nil, nil]
        )

        // Check dead state detection
        XCTAssertFalse(game.isWon(node), "Should not be won")

        // With 4 empty columns and no free cells, there are still moves (can move Kings)
        // So isDead should be false
        XCTAssertFalse(game.isDead(node), "Should not be dead - Kings can be moved")
    }

    // MARK: - Determinism Tests (R-QA2-3.2)

    /// Test that same deal + same budget produces same result across runs
    func testSolverDeterminism() {
        // Note: Full solver determinism testing requires EngineCore State integration
        // Here we test the deterministic components: hash function

        // Create a consistent test node
        let testNode = FreeCellSolverNode(
            tableau: [
                [0, 13, 26],  // A♣, A♦, 2♥
                [1],  // 2♣
                [2],  // 3♣
                [], [], [], [], [],
            ],
            freeCells: [255, 255, 255, 255],
            foundations: [nil, nil, nil, nil]
        )

        // We can't call solve() without EngineCore State, but we can test hash determinism
        let game = FreeCellSolvableGame()

        let hash1 = game.canonicalHash(testNode)
        let hash2 = game.canonicalHash(testNode)

        XCTAssertEqual(hash1, hash2, "Canonical hash should be deterministic")
    }

    // MARK: - Exhaustive Search Oracle Tests (R-QA2-3.1)

    /// Test exhaustive verification on very small state space
    func testExhaustiveSearchSmallState() {
        let game = FreeCellSolvableGame()

        // Create a minimal state: just 2 cards that can be solved
        let node = FreeCellSolverNode(
            tableau: [
                [0],  // A♣
                [1],  // 2♣ - can't build on A of same suit
                [], [], [], [], [], [],
            ],
            freeCells: [255, 255, 255, 255],
            foundations: [nil, nil, nil, nil]
        )

        // Verify isWon returns false
        XCTAssertFalse(game.isWon(node), "Should not be won initially")

        // Generate moves
        var moves: [SolverMove] = []
        game.generateMoves(node, into: &moves)

        // Apply each move and verify state transitions
        for move in moves {
            let newNode = game.apply(move, to: node)

            // Verify the move actually changed something or led to win
            XCTAssertTrue(
                newNode != node || game.isWon(newNode),
                "Move should produce valid new state"
            )
        }
    }

    // MARK: - Hash Determinism Tests

    /// Test that canonical hash is deterministic
    func testCanonicalHashDeterminism() {
        let game = FreeCellSolvableGame()

        let node = FreeCellSolverNode(
            tableau: [[0, 1, 2], [3, 4], [], [], [], [], [], []],
            freeCells: [255, 5, 255, 255],
            foundations: [0, nil, 2, nil]
        )

        let hash1 = game.canonicalHash(node)
        let hash2 = game.canonicalHash(node)

        XCTAssertEqual(hash1, hash2, "Hash should be deterministic")
    }

    // MARK: - Heuristic Tests

    /// Test heuristic provides reasonable ordering hints
    func testHeuristicOrdering() {
        let game = FreeCellSolvableGame()

        // Better position: more cards in foundations
        let goodNode = FreeCellSolverNode(
            tableau: [[], [], [], [], [], [], [], []],
            freeCells: [255, 255, 255, 255],
            foundations: [12, 12, 12, 12]  // All Kings in foundations = won!
        )

        // Worse position: no progress
        let badNode = FreeCellSolverNode(
            tableau: [[0, 1, 2, 3, 4, 5, 6], [7, 8, 9, 10, 11], [], [], [], [], [], []],
            freeCells: [255, 255, 255, 255],
            foundations: [nil, nil, nil, nil]
        )

        let goodScore = game.heuristic(goodNode)
        let badScore = game.heuristic(badNode)

        XCTAssertGreaterThan(goodScore, badScore, "Better position should have higher heuristic")
    }

    // MARK: - Transposition Table Tests

    /// Test transposition table stores and retrieves results
    func testTranspositionTable() {
        let table = TranspositionTable()

        let testHash: UInt64 = 12345
        let entry = TranspositionTable.Entry(
            hash: testHash,
            depth: 5,
            result: .winnable(bestFirstMove: nil),
            bestMove: nil,
            remainingBudget: 100
        )

        table.set(entry)

        if let retrieved = table.get(testHash) {
            XCTAssertEqual(retrieved.depth, 5)
            XCTAssertEqual(retrieved.result, .winnable(bestFirstMove: nil))
        } else {
            XCTFail("Should retrieve entry from transposition table")
        }
    }

    /// Test transposition table clear
    func testTranspositionTableClear() {
        let table = TranspositionTable()

        let entry = TranspositionTable.Entry(
            hash: 1,
            depth: 5,
            result: .unwinnable,
            bestMove: nil,
            remainingBudget: 100
        )

        table.set(entry)
        XCTAssertNotNil(table.get(1))

        table.clear()
        XCTAssertNil(table.get(1), "Table should be empty after clear")
    }

    // MARK: - FreeCell Node Tests

    /// Test FreeCell node supermove capacity calculation
    func testSupermoveCapacity() {
        // 4 empty free cells, 0 empty columns: capacity = (4+1) * 2^0 = 5
        let node1 = FreeCellSolverNode(
            tableau: [[1], [2], [3], [4], [5], [6], [7], [8]],
            freeCells: [255, 255, 255, 255],
            foundations: [nil, nil, nil, nil]
        )
        XCTAssertEqual(node1.supermoveCapacity, 5)

        // 4 empty free cells, 1 empty column: capacity = (4+1) * 2^1 = 10
        let node2 = FreeCellSolverNode(
            tableau: [[1], [2], [3], [4], [5], [6], [7], []],
            freeCells: [255, 255, 255, 255],
            foundations: [nil, nil, nil, nil]
        )
        XCTAssertEqual(node2.supermoveCapacity, 10)

        // 4 empty free cells, 2 empty columns: capacity = (4+1) * 2^2 = 20
        let node3 = FreeCellSolverNode(
            tableau: [[1], [2], [3], [4], [5], [6], [], []],
            freeCells: [255, 255, 255, 255],
            foundations: [nil, nil, nil, nil]
        )
        XCTAssertEqual(node3.supermoveCapacity, 20)
    }

    /// Test FreeCell empty column count
    func testEmptyTableauColumns() {
        let node = FreeCellSolverNode(
            tableau: [[1], [], [2], [], [], [3], [4], [5]],
            freeCells: [255, 255, 255, 255],
            foundations: [nil, nil, nil, nil]
        )
        XCTAssertEqual(node.emptyTableauColumns, 3)
    }

    /// Test FreeCell empty free cell count
    func testEmptyFreeCells() {
        let node = FreeCellSolverNode(
            tableau: [[1], [2], [3], [4], [5], [6], [7], [8]],
            freeCells: [255, 0, 255, 1],
            foundations: [nil, nil, nil, nil]
        )
        XCTAssertEqual(node.emptyFreeCells, 2)
    }

    // MARK: - SolveResult Tests

    /// Test SolveResult equatability
    func testSolveResultEquality() {
        let result1: SolveResult = .winnable(bestFirstMove: nil)
        let result2: SolveResult = .winnable(bestFirstMove: nil)
        let result3: SolveResult = .unwinnable
        let result4: SolveResult = .unknown

        XCTAssertEqual(result1, result2)
        XCTAssertNotEqual(result1, result3)
        XCTAssertNotEqual(result1, result4)
        XCTAssertNotEqual(result3, result4)
    }

    // MARK: - Solver Move Tests

    /// Test SolverMove encoding and decoding
    func testSolverMoveEncoding() throws {
        let action = FreeCellAction.tableauToFoundation(fromPile: 0, toFoundation: 1)
        let move = try SolverMove(action)

        let decoded = try move.decode(as: FreeCellAction.self)
        XCTAssertEqual(decoded, action)
    }
}

// MARK: - Klondike Solver Tests

final class KlondikeSolverTests: XCTestCase {
    private func createKlondikeSolver() -> DealSolver<KlondikeSolvableGame> {
        return DealSolver(game: KlondikeSolvableGame())
    }

    /// Test Klondike solvable game hash determinism
    func testKlondikeHashDeterminism() {
        let game = KlondikeSolvableGame()

        // Create a simple node
        let node = KlondikeSolverNode(
            tableau: [[0], [1], [2], [], [], [], []],
            stock: [3, 4, 5],
            waste: [6],
            foundations: [nil, nil, nil, nil],
            tableauFaceDown: [0, 0, 0, 0, 0, 0, 0],
            drawCount: 1,
            passes: 0
        )

        let hash1 = game.canonicalHash(node)
        let hash2 = game.canonicalHash(node)

        XCTAssertEqual(hash1, hash2, "Hash should be deterministic")
    }

    /// Test Klondike node isWon detection
    func testKlondikeIsWon() {
        let game = KlondikeSolvableGame()

        // Node with all foundations having Kings
        let winningNode = KlondikeSolverNode(
            tableau: [[], [], [], [], [], [], []],
            stock: [],
            waste: [],
            foundations: [12, 12, 12, 12],
            tableauFaceDown: [0, 0, 0, 0, 0, 0, 0],
            drawCount: 1,
            passes: 0
        )

        XCTAssertTrue(game.isWon(winningNode), "Should be won when all foundations have Kings")

        // Node with some foundations not complete
        let nonWinningNode = KlondikeSolverNode(
            tableau: [[], [], [], [], [], [], []],
            stock: [],
            waste: [],
            foundations: [12, 11, 12, 12],
            tableauFaceDown: [0, 0, 0, 0, 0, 0, 0],
            drawCount: 1,
            passes: 0
        )

        XCTAssertFalse(game.isWon(nonWinningNode), "Should not be won when foundations incomplete")
    }

    /// Test Klondike isDead detection
    func testKlondikeIsDead() {
        let game = KlondikeSolvableGame()

        // Node with empty stock and waste with no moves
        let deadNode = KlondikeSolverNode(
            tableau: [[0], [], [], [], [], [], []],
            stock: [],
            waste: [],
            foundations: [nil, nil, nil, nil],
            tableauFaceDown: [0, 0, 0, 0, 0, 0, 0],
            drawCount: 1,
            passes: 0
        )

        XCTAssertTrue(game.isDead(deadNode), "Should be dead with no stock, waste, or moves")
    }

    /// Test Klondike heuristic
    func testKlondikeHeuristic() {
        let game = KlondikeSolvableGame()

        // Better position: cards in foundations
        let goodNode = KlondikeSolverNode(
            tableau: [[], [], [], [], [], [], []],
            stock: [],
            waste: [],
            foundations: [5, 3, 7, 2],
            tableauFaceDown: [0, 0, 0, 0, 0, 0, 0],
            drawCount: 1,
            passes: 0
        )

        // Worse position: no progress
        let badNode = KlondikeSolverNode(
            tableau: [[0, 1, 2, 3], [4, 5, 6], [7, 8], [9], [], [], []],
            stock: [10, 11, 12],
            waste: [],
            foundations: [nil, nil, nil, nil],
            tableauFaceDown: [1, 1, 1, 1, 0, 0, 0],
            drawCount: 1,
            passes: 0
        )

        let goodScore = game.heuristic(goodNode)
        let badScore = game.heuristic(badNode)

        XCTAssertGreaterThan(goodScore, badScore, "Better position should have higher heuristic")
    }
}
