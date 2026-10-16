// Simulation harness — invariant-checked AI and random-legal runs (R-QA-2.1, R-QA-2.2).
//
// The harness deliberately drives the pure GameDefinition APIs directly. It never mutates a game state
// outside apply(_:by:to:), records the concrete action sequence, and replays that sequence from the same
// seed before declaring a run deterministic. This keeps the simulation contract identical to the host's
// rules boundary while avoiding UI, persistence, or actor scheduling in a volume test.

import AIKit
import EngineCore
import Foundation
import GamesRules

// MARK: - Public simulation contract

/// A game covered by the platform simulation gate.
public enum SimulationGame: String, Codable, CaseIterable, Sendable {
    case klondike
    case crazyEights = "crazy-eights"
}

/// The policy used to select legal actions during a simulation.
public enum SimulationMode: String, Codable, CaseIterable, Sendable {
    /// Crazy Eights uses the production Easy AI strategy for every seat. Klondike is single-seat and uses
    /// its production hint policy as the deterministic player controller.
    case aiVsAI = "ai-vs-ai"
    /// Select one action uniformly from the definition's legal-action list using an injected seed.
    case randomLegal = "random-legal"
}

/// How a simulation stopped. A bounded stop is intentional for unsolved/non-terminal Klondike deals;
/// it prevents a pathological legal-action cycle from making the volume gate unbounded.
public enum SimulationTermination: String, Codable, Hashable, Sendable {
    case terminal
    case actionLimit
    case noLegalActions
}

/// The five invariant results required by R-QA-2.1.
public struct SimulationInvariantChecks: Codable, Hashable, Sendable {
    public let pieceConservation: Bool
    public let onlyLegalActions: Bool
    public let boundedLength: Bool
    public let scoringConsistency: Bool
    public let deterministicReplay: Bool

    public init(
        pieceConservation: Bool,
        onlyLegalActions: Bool,
        boundedLength: Bool,
        scoringConsistency: Bool,
        deterministicReplay: Bool
    ) {
        self.pieceConservation = pieceConservation
        self.onlyLegalActions = onlyLegalActions
        self.boundedLength = boundedLength
        self.scoringConsistency = scoringConsistency
        self.deterministicReplay = deterministicReplay
    }

    public var allPassed: Bool {
        pieceConservation && onlyLegalActions && boundedLength && scoringConsistency
            && deterministicReplay
    }
}

/// The result of one seed/mode/game run.
public struct SimulationRun: Codable, Hashable, Sendable {
    public let game: SimulationGame
    public let mode: SimulationMode
    public let seed: UInt64
    public let actionCount: Int
    public let maxActions: Int
    public let termination: SimulationTermination
    public let finalHash: StateHash
    public let checks: SimulationInvariantChecks

    public init(
        game: SimulationGame,
        mode: SimulationMode,
        seed: UInt64,
        actionCount: Int,
        maxActions: Int,
        termination: SimulationTermination,
        finalHash: StateHash,
        checks: SimulationInvariantChecks
    ) {
        self.game = game
        self.mode = mode
        self.seed = seed
        self.actionCount = actionCount
        self.maxActions = maxActions
        self.termination = termination
        self.finalHash = finalHash
        self.checks = checks
    }

    public var passed: Bool { checks.allPassed }
}

/// Aggregate result printed by `parlor-sim` and returned to unit tests.
public struct SimulationBatchReport: Codable, Sendable {
    public let gamesPerGame: Int
    public let maxActions: Int
    public let runs: [SimulationRun]

    public init(gamesPerGame: Int, maxActions: Int, runs: [SimulationRun]) {
        self.gamesPerGame = gamesPerGame
        self.maxActions = maxActions
        self.runs = runs
    }

    public var allPassed: Bool { runs.allSatisfy(\.passed) }
    public var runCount: Int { runs.count }
    public var terminalCount: Int {
        runs.count { $0.termination == .terminal }
    }
    public var boundedStopCount: Int {
        runs.count { $0.termination != .terminal }
    }

    public func runs(for game: SimulationGame, mode: SimulationMode) -> [SimulationRun] {
        runs.filter { $0.game == game && $0.mode == mode }
    }
}

/// A typed invariant failure. The CLI prints this and exits non-zero; tests can inspect the exact action
/// index and seed without parsing process output.
public struct SimulationError: Error, CustomStringConvertible, Sendable {
    public let game: SimulationGame
    public let mode: SimulationMode
    public let seed: UInt64
    public let actionIndex: Int
    public let invariant: String
    public let reason: String

    public init(
        game: SimulationGame,
        mode: SimulationMode,
        seed: UInt64,
        actionIndex: Int,
        invariant: String,
        reason: String
    ) {
        self.game = game
        self.mode = mode
        self.seed = seed
        self.actionIndex = actionIndex
        self.invariant = invariant
        self.reason = reason
    }

    public var description: String {
        "\(game.rawValue)/\(mode.rawValue) seed=\(seed) action=\(actionIndex) "
            + "invariant=\(invariant): \(reason)"
    }
}

// MARK: - Runner

/// Runs the invariant suite for both reference games.
public enum SimulationRunner {
    /// The finite Crazy Eights configuration used by the quality gate. Ending on an exhausted stock
    /// keeps the random-legal lane finite without allowing an unbounded discard reshuffle cycle.
    public static let crazyEightsOptions = CrazyEightsOptions(
        playerCount: 2,
        drawMode: .drawOneThenPass,
        stockOut: .endHand,
        matchTarget: 100,
        actionCards: false)

    /// The standard-scoring Klondike configuration used by the quality gate. One stock pass bounds the
    /// stock cycle; the action cap bounds legal tableau/foundation cycles on unsolved deals.
    public static let klondikeOptions = KlondikeOptions(
        drawCount: .one,
        scoring: .standard,
        stockPasses: .limited(1),
        timed: false,
        vegasCumulative: false,
        autoFlip: true,
        autoMove: .off,
        debugNearWin: false)

    /// Run one game and one policy for a supplied seed.
    public static func run(
        game: SimulationGame,
        mode: SimulationMode,
        seed: UInt64,
        maxActions: Int = 512
    ) async throws -> SimulationRun {
        guard maxActions > 0 else {
            throw SimulationError(
                game: game,
                mode: mode,
                seed: seed,
                actionIndex: 0,
                invariant: "bounded-length",
                reason: "maxActions must be greater than zero")
        }

        switch game {
        case .klondike:
            return try runKlondike(mode: mode, seed: seed, maxActions: maxActions)
        case .crazyEights:
            return try await runCrazyEights(mode: mode, seed: seed, maxActions: maxActions)
        }
    }

    /// Run `gamesPerGame` seeds for each game and each requested mode. The returned report is all-pass
    /// only when every run checked every invariant successfully.
    public static func runBatch(
        gamesPerGame: Int,
        seeds: [UInt64],
        maxActions: Int = 512,
        games: [SimulationGame] = [.klondike, .crazyEights],
        modes: [SimulationMode] = [.aiVsAI, .randomLegal]
    ) async throws -> SimulationBatchReport {
        guard gamesPerGame > 0 else {
            throw SimulationError(
                game: .klondike,
                mode: .randomLegal,
                seed: 0,
                actionIndex: 0,
                invariant: "batch-configuration",
                reason: "gamesPerGame must be greater than zero")
        }
        guard seeds.count >= gamesPerGame else {
            throw SimulationError(
                game: .klondike,
                mode: .randomLegal,
                seed: 0,
                actionIndex: 0,
                invariant: "seed-pool",
                reason: "seed pool contains \(seeds.count) values; need \(gamesPerGame)")
        }

        var runs: [SimulationRun] = []
        runs.reserveCapacity(games.count * modes.count * gamesPerGame)
        for game in games {
            for mode in modes {
                for seed in seeds.prefix(gamesPerGame) {
                    let run = try await run(
                        game: game, mode: mode, seed: seed, maxActions: maxActions)
                    guard run.passed else {
                        throw SimulationError(
                            game: game,
                            mode: mode,
                            seed: seed,
                            actionIndex: run.actionCount,
                            invariant: "aggregate",
                            reason: "one or more invariant checks failed")
                    }
                    runs.append(run)
                }
            }
        }
        return SimulationBatchReport(
            gamesPerGame: gamesPerGame, maxActions: maxActions, runs: runs)
    }

    // MARK: Klondike

    private struct KlondikeRecord {
        let seat: SeatID
        let action: KlondikeAction
    }

    private static func runKlondike(
        mode: SimulationMode, seed: UInt64, maxActions: Int
    ) throws -> SimulationRun {
        let game = Klondike()
        var state = game.initialState(options: klondikeOptions, seed: seed)
        let expectedPieces = Set(state.allZones.flatMap(\.contents))
        let expectedFaces = Set(state.faces.keys)
        try checkPieceConservation(
            state.allZones,
            expectedPieces: expectedPieces,
            expectedFaces: expectedFaces,
            game: .klondike,
            mode: mode,
            seed: seed,
            actionIndex: 0)

        var chooserRNG = SeededRNG(seed: seed ^ 0x4B4C_4F4E_4449_4B45)
        var records: [KlondikeRecord] = []
        records.reserveCapacity(maxActions)
        var scoringConsistent = true
        var termination: SimulationTermination?

        while !game.isTerminal(state) {
            guard records.count < maxActions else {
                termination = .actionLimit
                break
            }
            let seat = klondikeSeat
            let legal = game.legalActions(for: seat, in: state)
            guard !legal.isEmpty else {
                termination = .noLegalActions
                break
            }

            let action: KlondikeAction
            switch mode {
            case .aiVsAI:
                // Klondike has one seat and no opponent. Its production hint policy is the deterministic
                // AI controller for this lane; the random seed still drives the replayable run's fallback.
                action = game.hint(state) ?? legal[Int(chooserRNG.next() % UInt64(legal.count))]
            case .randomLegal:
                action = legal[Int(chooserRNG.next() % UInt64(legal.count))]
            }

            guard legal.contains(action) else {
                throw makeError(
                    game: .klondike,
                    mode: mode,
                    seed: seed,
                    actionIndex: records.count,
                    invariant: "only-legal-actions",
                    reason: "chooser returned an action outside legalActions")
            }
            guard case .success(let (next, events)) = game.apply(action, by: seat, to: state)
            else {
                throw makeError(
                    game: .klondike,
                    mode: mode,
                    seed: seed,
                    actionIndex: records.count,
                    invariant: "only-legal-actions",
                    reason: "a legal action was rejected by apply")
            }

            let scoreOK = checkKlondikeScoring(
                previous: state, next: next, events: events, game: game)
            scoringConsistent = scoringConsistent && scoreOK
            guard scoreOK else {
                throw makeError(
                    game: .klondike,
                    mode: mode,
                    seed: seed,
                    actionIndex: records.count,
                    invariant: "scoring-consistency",
                    reason: "score or scoreChanged event totals do not reconcile")
            }
            try checkPieceConservation(
                next.allZones,
                expectedPieces: expectedPieces,
                expectedFaces: expectedFaces,
                game: .klondike,
                mode: mode,
                seed: seed,
                actionIndex: records.count + 1)
            records.append(KlondikeRecord(seat: seat, action: action))
            state = next
        }

        if termination == nil {
            termination = game.isTerminal(state) ? .terminal : .noLegalActions
        }
        let replayed = try replayKlondike(game: game, seed: seed, records: records, mode: mode)
        let finalHash = try stableKlondikeHash(
            state,
            game: .klondike,
            mode: mode,
            seed: seed,
            actionIndex: records.count)
        let replayHash = try stableKlondikeHash(
            replayed,
            game: .klondike,
            mode: mode,
            seed: seed,
            actionIndex: records.count)
        let deterministic = finalHash == replayHash
        guard deterministic else {
            throw makeError(
                game: .klondike,
                mode: mode,
                seed: seed,
                actionIndex: records.count,
                invariant: "deterministic-replay",
                reason: "replayed final hash \(replayHash) differs from \(finalHash)")
        }

        if game.isTerminal(state) {
            let outcome = game.outcome(state)
            let expectedScore = state.options.scoring == .none ? 0 : state.score
            guard outcome.scores[klondikeSeat] == expectedScore else {
                throw makeError(
                    game: .klondike,
                    mode: mode,
                    seed: seed,
                    actionIndex: records.count,
                    invariant: "scoring-consistency",
                    reason: "terminal outcome score does not equal state score")
            }
        }

        let checks = SimulationInvariantChecks(
            pieceConservation: true,
            onlyLegalActions: true,
            boundedLength: records.count <= maxActions,
            scoringConsistency: scoringConsistent,
            deterministicReplay: deterministic)
        return SimulationRun(
            game: .klondike,
            mode: mode,
            seed: seed,
            actionCount: records.count,
            maxActions: maxActions,
            termination: termination!,
            finalHash: finalHash,
            checks: checks)
    }

    private static func replayKlondike(
        game: Klondike,
        seed: UInt64,
        records: [KlondikeRecord],
        mode: SimulationMode
    ) throws -> KlondikeState {
        var state = game.initialState(options: klondikeOptions, seed: seed)
        for (index, record) in records.enumerated() {
            let legal = game.legalActions(for: record.seat, in: state)
            guard legal.contains(record.action) else {
                throw makeError(
                    game: .klondike,
                    mode: mode,
                    seed: seed,
                    actionIndex: index,
                    invariant: "deterministic-replay",
                    reason: "recorded action is not legal during replay")
            }
            guard
                case .success(let (next, _)) = game.apply(
                    record.action, by: record.seat, to: state)
            else {
                throw makeError(
                    game: .klondike,
                    mode: mode,
                    seed: seed,
                    actionIndex: index,
                    invariant: "deterministic-replay",
                    reason: "recorded legal action was rejected during replay")
            }
            state = next
        }
        return state
    }

    private static func checkKlondikeScoring(
        previous: KlondikeState,
        next: KlondikeState,
        events: [GameEvent],
        game: Klondike
    ) -> Bool {
        var expected = previous.score
        for event in events {
            guard case .scoreChanged(_, let delta, let total) = event else { continue }
            expected += delta
            guard total == expected else { return false }
        }
        guard expected == next.score else { return false }
        if game.isTerminal(next) {
            let outcome = game.outcome(next)
            let expectedScore = next.options.scoring == .none ? 0 : next.score
            guard outcome.scores[klondikeSeat] == expectedScore else { return false }
            guard
                events.contains(where: { event in
                    if case .handEnded(let ended) = event { return ended == outcome }
                    return false
                })
            else { return false }
        }
        return true
    }

    // MARK: Crazy Eights

    private struct CrazyEightsRecord {
        let seat: SeatID
        let action: CrazyEightsAction
    }

    private static func runCrazyEights(
        mode: SimulationMode, seed: UInt64, maxActions: Int
    ) async throws -> SimulationRun {
        let game = CrazyEights()
        var state = game.initialState(options: crazyEightsOptions, seed: seed)
        let expectedPieces = Set(state.allZones.flatMap(\.contents))
        let expectedFaces = Set(state.faces.keys)
        try checkPieceConservation(
            state.allZones,
            expectedPieces: expectedPieces,
            expectedFaces: expectedFaces,
            game: .crazyEights,
            mode: mode,
            seed: seed,
            actionIndex: 0)

        let strategy = CrazyEightsEasyStrategy()
        var chooserRNG = SeededRNG(seed: seed ^ 0x4352_415A_5959_4549)
        var records: [CrazyEightsRecord] = []
        records.reserveCapacity(maxActions)
        var scoringConsistent = true
        var termination: SimulationTermination?

        while !game.isTerminal(state) {
            guard records.count < maxActions else {
                termination = .actionLimit
                break
            }
            let seat = state.turn
            let legal = game.legalActions(for: seat, in: state)
            guard !legal.isEmpty else {
                termination = .noLegalActions
                break
            }

            let action: CrazyEightsAction
            switch mode {
            case .randomLegal:
                action = legal[Int(chooserRNG.next() % UInt64(legal.count))]
            case .aiVsAI:
                let erased = try legal.map(AnyGameAction.init)
                let decisionSeed = chooserRNG.next()
                let context = DecisionContext(
                    view: game.redactedView(of: state, for: .seat(seat)),
                    publicLog: .empty,
                    seat: seat,
                    legalActions: erased,
                    rng: SeededRNG(seed: decisionSeed),
                    deadline: .never)
                guard let chosen = await strategy.decide(context),
                    let decoded = try? chosen.decode(as: CrazyEightsAction.self)
                else {
                    throw makeError(
                        game: .crazyEights,
                        mode: mode,
                        seed: seed,
                        actionIndex: records.count,
                        invariant: "only-legal-actions",
                        reason: "AI returned no decodable action")
                }
                action = decoded
            }

            guard legal.contains(action) else {
                throw makeError(
                    game: .crazyEights,
                    mode: mode,
                    seed: seed,
                    actionIndex: records.count,
                    invariant: "only-legal-actions",
                    reason: "chooser returned an action outside legalActions")
            }
            guard case .success(let (next, events)) = game.apply(action, by: seat, to: state)
            else {
                throw makeError(
                    game: .crazyEights,
                    mode: mode,
                    seed: seed,
                    actionIndex: records.count,
                    invariant: "only-legal-actions",
                    reason: "a legal action was rejected by apply")
            }

            let scoreOK = checkCrazyEightsScoring(game: game, next: next, events: events)
            scoringConsistent = scoringConsistent && scoreOK
            guard scoreOK else {
                throw makeError(
                    game: .crazyEights,
                    mode: mode,
                    seed: seed,
                    actionIndex: records.count,
                    invariant: "scoring-consistency",
                    reason:
                        "terminal hand outcome does not equal independently calculated card values")
            }
            try checkPieceConservation(
                next.allZones,
                expectedPieces: expectedPieces,
                expectedFaces: expectedFaces,
                game: .crazyEights,
                mode: mode,
                seed: seed,
                actionIndex: records.count + 1)
            records.append(CrazyEightsRecord(seat: seat, action: action))
            state = next
        }

        if termination == nil {
            termination = game.isTerminal(state) ? .terminal : .noLegalActions
        }
        let replayed = try replayCrazyEights(game: game, seed: seed, records: records, mode: mode)
        let finalHash = try stableCrazyEightsHash(
            state,
            game: .crazyEights,
            mode: mode,
            seed: seed,
            actionIndex: records.count)
        let replayHash = try stableCrazyEightsHash(
            replayed,
            game: .crazyEights,
            mode: mode,
            seed: seed,
            actionIndex: records.count)
        let deterministic = finalHash == replayHash
        guard deterministic else {
            throw makeError(
                game: .crazyEights,
                mode: mode,
                seed: seed,
                actionIndex: records.count,
                invariant: "deterministic-replay",
                reason: "replayed final hash \(replayHash) differs from \(finalHash)")
        }
        if game.isTerminal(state) {
            let finalScoreOK = checkCrazyEightsScoring(game: game, next: state, events: [])
            scoringConsistent = scoringConsistent && finalScoreOK
            guard finalScoreOK else {
                throw makeError(
                    game: .crazyEights,
                    mode: mode,
                    seed: seed,
                    actionIndex: records.count,
                    invariant: "scoring-consistency",
                    reason: "final hand outcome is inconsistent")
            }
        }

        let checks = SimulationInvariantChecks(
            pieceConservation: true,
            onlyLegalActions: true,
            boundedLength: records.count <= maxActions,
            scoringConsistency: scoringConsistent,
            deterministicReplay: deterministic)
        return SimulationRun(
            game: .crazyEights,
            mode: mode,
            seed: seed,
            actionCount: records.count,
            maxActions: maxActions,
            termination: termination!,
            finalHash: finalHash,
            checks: checks)
    }

    private static func replayCrazyEights(
        game: CrazyEights,
        seed: UInt64,
        records: [CrazyEightsRecord],
        mode: SimulationMode
    ) throws -> CrazyEightsState {
        var state = game.initialState(options: crazyEightsOptions, seed: seed)
        for (index, record) in records.enumerated() {
            let legal = game.legalActions(for: record.seat, in: state)
            guard legal.contains(record.action) else {
                throw makeError(
                    game: .crazyEights,
                    mode: mode,
                    seed: seed,
                    actionIndex: index,
                    invariant: "deterministic-replay",
                    reason: "recorded action is not legal during replay")
            }
            guard
                case .success(let (next, _)) = game.apply(
                    record.action, by: record.seat, to: state)
            else {
                throw makeError(
                    game: .crazyEights,
                    mode: mode,
                    seed: seed,
                    actionIndex: index,
                    invariant: "deterministic-replay",
                    reason: "recorded legal action was rejected during replay")
            }
            state = next
        }
        return state
    }

    private static func checkCrazyEightsScoring(
        game: CrazyEights,
        next: CrazyEightsState,
        events: [GameEvent]
    ) -> Bool {
        guard
            let ended = next.hands.first(where: { $0.contents.isEmpty })?.owner
                ?? (game.isTerminal(next) ? game.outcome(next).winners.first : nil)
        else {
            // A non-terminal state has no hand score to reconcile. It still receives conservation and
            // legal-action checks at every step.
            return !events.contains {
                if case .handEnded = $0 { return true }; return false
            }
        }

        let outcome = game.outcome(next)
        guard outcome.winners.count == 1, outcome.winners[0] == ended,
            outcome.scores.count == 1,
            let earned = outcome.scores[ended]
        else { return false }

        var held: [SeatID: Int] = [:]
        for hand in next.hands {
            guard let owner = hand.owner else { continue }
            held[owner] = hand.contents.reduce(0) { total, id in
                total + (next.faces[id].map(crazyEightsPoints) ?? 0)
            }
        }
        let expectedEarned = held.reduce(0) { total, entry in
            entry.key == ended ? total : total + entry.value
        }
        guard earned == expectedEarned else { return false }

        if next.hands.allSatisfy({ !$0.contents.isEmpty }) {
            guard let winnerPoints = held[ended],
                held.values.allSatisfy({ winnerPoints <= $0 })
            else { return false }
        }

        // A player going out emits handEnded. A stock-exhaustion/stuck hand is terminal by rule but its
        // pass transition deliberately emits no handEnded event, so absence is valid in that case.
        if next.hands.contains(where: { $0.contents.isEmpty }) && !events.isEmpty {
            guard
                events.contains(where: { event in
                    if case .handEnded(let eventOutcome) = event { return eventOutcome == outcome }
                    return false
                })
            else { return false }
        }
        return true
    }

    private static func crazyEightsPoints(_ face: CardFace) -> Int {
        guard case .standard(let rank, _) = face else { return 0 }
        switch rank {
        case .eight: return 50
        case .jack, .queen, .king: return 10
        case .ace: return 1
        default: return rank.rawValue
        }
    }

    // MARK: Stable final-state hashing

    // JSONEncoder's sortedKeys option sorts string-keyed dictionaries but does not promise an order for
    // dictionaries keyed by PieceID. The simulation projection sorts those entries explicitly so the
    // replay hash tests the logical state, not hash-table iteration order.
    private struct StableFace: Codable {
        let id: PieceID
        let face: CardFace
    }

    private struct StableZone: Codable {
        let id: ZoneID
        let visibility: Visibility
        let contents: [PieceID]
        let faceUp: [PieceID]

        init(_ zone: Zone) {
            id = zone.id
            visibility = zone.visibility
            contents = zone.contents
            faceUp = zone.faceUp.sorted { $0.raw < $1.raw }
        }
    }

    private struct StableKlondikeState: Codable {
        let stock: StableZone
        let waste: StableZone
        let tableau: [StableZone]
        let foundations: [StableZone]
        let faces: [StableFace]
        let score: Int
        let passes: Int
        let options: KlondikeOptions

        init(_ state: KlondikeState) {
            stock = StableZone(state.stock)
            waste = StableZone(state.waste)
            tableau = state.tableau.map(StableZone.init)
            foundations = state.foundations.map(StableZone.init)
            faces = state.faces.map { StableFace(id: $0.key, face: $0.value) }
                .sorted { $0.id.raw < $1.id.raw }
            score = state.score
            passes = state.passes
            options = state.options
        }
    }

    private struct StableCrazyEightsState: Codable {
        let hands: [StableZone]
        let stock: StableZone
        let discard: StableZone
        let faces: [StableFace]
        let activeSuit: Suit
        let turn: SeatID
        let direction: CrazyEightsDirection
        let pendingDraw: Int
        let options: CrazyEightsOptions

        init(_ state: CrazyEightsState) {
            hands = state.hands.map(StableZone.init)
            stock = StableZone(state.stock)
            discard = StableZone(state.discard)
            faces = state.faces.map { StableFace(id: $0.key, face: $0.value) }
                .sorted { $0.id.raw < $1.id.raw }
            activeSuit = state.activeSuit
            turn = state.turn
            direction = state.direction
            pendingDraw = state.pendingDraw
            options = state.options
        }
    }

    private static func stableKlondikeHash(
        _ state: KlondikeState,
        game: SimulationGame,
        mode: SimulationMode,
        seed: UInt64,
        actionIndex: Int
    ) throws -> StateHash {
        try canonicalHash(
            StableKlondikeState(state),
            game: game,
            mode: mode,
            seed: seed,
            actionIndex: actionIndex)
    }

    private static func stableCrazyEightsHash(
        _ state: CrazyEightsState,
        game: SimulationGame,
        mode: SimulationMode,
        seed: UInt64,
        actionIndex: Int
    ) throws -> StateHash {
        try canonicalHash(
            StableCrazyEightsState(state),
            game: game,
            mode: mode,
            seed: seed,
            actionIndex: actionIndex)
    }

    // MARK: Shared invariant helpers

    private static func checkPieceConservation(
        _ zones: [Zone],
        expectedPieces: Set<PieceID>,
        expectedFaces: Set<PieceID>,
        game: SimulationGame,
        mode: SimulationMode,
        seed: UInt64,
        actionIndex: Int
    ) throws {
        let pieces = zones.flatMap(\.contents)
        guard pieces.count == Set(pieces).count else {
            throw makeError(
                game: game,
                mode: mode,
                seed: seed,
                actionIndex: actionIndex,
                invariant: "piece-conservation",
                reason: "a piece identity occurs in more than one zone")
        }
        guard Set(pieces) == expectedPieces else {
            throw makeError(
                game: game,
                mode: mode,
                seed: seed,
                actionIndex: actionIndex,
                invariant: "piece-conservation",
                reason: "a piece was lost or introduced")
        }
        guard Set(pieces) == expectedFaces else {
            throw makeError(
                game: game,
                mode: mode,
                seed: seed,
                actionIndex: actionIndex,
                invariant: "piece-conservation",
                reason: "zone contents and face map disagree")
        }
    }

    private static func canonicalHash<Value: Encodable>(
        _ value: Value,
        game: SimulationGame,
        mode: SimulationMode,
        seed: UInt64,
        actionIndex: Int
    ) throws -> StateHash {
        do {
            return try StateHash.canonical(value)
        } catch {
            throw makeError(
                game: game,
                mode: mode,
                seed: seed,
                actionIndex: actionIndex,
                invariant: "deterministic-replay",
                reason: "state could not be canonically hashed: \(error)")
        }
    }

    private static func makeError(
        game: SimulationGame,
        mode: SimulationMode,
        seed: UInt64,
        actionIndex: Int,
        invariant: String,
        reason: String
    ) -> SimulationError {
        SimulationError(
            game: game,
            mode: mode,
            seed: seed,
            actionIndex: actionIndex,
            invariant: invariant,
            reason: reason)
    }
}
