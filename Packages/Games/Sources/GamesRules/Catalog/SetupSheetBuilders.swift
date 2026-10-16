// Setup-sheet builders for the two built games — turning each game's options schema into a
// `SetupSheetModel` (R-APP-2).
//
// The setup sheet is a game-agnostic descriptor (SetupSheetModel.swift); each game classifies its own
// options into the "Options" vs "House Rules" groups and writes the one-line explanations R-APP-2.1
// requires. These builders are the per-game contribution — adding a game means writing its builder, not
// new UI (design.md §11). Presets come straight from the game's `optionsSchema.presets` (R-ENG-5.2), so
// they stay in sync with the rules layer.
//
// The explanations are original one-liners paraphrasing the option semantics documented in
// `Docs/Rules/<game-id>.md`; they mirror the docstrings on `KlondikeOptions` / `CrazyEightsOptions`.

import EngineCore
import Foundation

// MARK: - Klondike (solo — no opponents)

extension Klondike {
    /// Build the setup sheet for Klondike from its options (R-APP-2).
    ///
    /// Presets first (from `optionsSchema`), then Options (draw count, scoring, stock passes, timed) and
    /// House Rules (auto-flip, auto-move) grouped separately, each with a one-line explanation (R-APP-2.1).
    /// Klondike is solo (seat range 1...1), so the opponent section is `.solo` (R-APP-2.2 applies only
    /// where opponents exist). `rememberChoices` defaults off; the App flips and persists it.
    public static func setupSheet(
        options: KlondikeOptions = optionsSchema.defaults,
        rememberChoices: Bool = false
    ) -> SetupSheetModel {
        let presets = optionsSchema.presets.map { preset in
            SetupPreset(
                name: preset.name,
                explanation: "Starts from the \(preset.name) configuration.")
        }

        let optionControls: [SetupControl] = [
            SetupControl(
                id: "draw-count",
                title: "Draw count",
                explanation: "How many cards you turn from the stock at a time.",
                kind: .choice(
                    options: [
                        SetupOption(id: "one", label: "Draw 1"),
                        SetupOption(id: "three", label: "Draw 3"),
                    ],
                    selected: options.drawCount == .one ? "one" : "three")),
            SetupControl(
                id: "scoring",
                title: "Scoring",
                explanation: "Standard points, Vegas money, or no score at all.",
                kind: .choice(
                    options: [
                        SetupOption(id: "standard", label: "Standard"),
                        SetupOption(id: "vegas", label: "Vegas"),
                        SetupOption(id: "none", label: "None"),
                    ],
                    selected: options.scoring.rawValue)),
            SetupControl(
                id: "stock-passes",
                title: "Stock passes",
                explanation: "How many times you may run through the stock.",
                kind: .choice(
                    options: [
                        SetupOption(id: "unlimited", label: "Unlimited"),
                        SetupOption(id: "three", label: "3 passes"),
                        SetupOption(id: "one", label: "1 pass"),
                    ],
                    selected: stockPassesID(options.stockPasses))),
            SetupControl(
                id: "timed",
                title: "Timed scoring",
                explanation: "Add a time bonus that rewards finishing quickly.",
                kind: .toggle(isOn: options.timed)),
        ]

        let houseRuleControls: [SetupControl] = [
            SetupControl(
                id: "auto-flip",
                title: "Auto-flip",
                explanation: "Turn a newly exposed tableau card face up for you.",
                kind: .toggle(isOn: options.autoFlip)),
            SetupControl(
                id: "auto-move",
                title: "Auto-move to foundation",
                explanation: "Send cards home automatically — off, only when safe, or always.",
                kind: .choice(
                    options: [
                        SetupOption(id: "off", label: "Off"),
                        SetupOption(id: "safeOnly", label: "Safe only"),
                        SetupOption(id: "always", label: "Always"),
                    ],
                    selected: options.autoMove.rawValue)),
        ]

        return SetupSheetModel(
            gameID: metadata.id,
            gameName: metadata.name,
            presets: presets,
            groups: [
                SetupGroup(kind: .options, controls: optionControls),
                SetupGroup(kind: .houseRules, controls: houseRuleControls),
            ],
            opponents: .solo,
            rememberChoices: rememberChoices)
    }

    /// The choice-option id for a stock-passes value.
    private static func stockPassesID(_ passes: KlondikeStockPasses) -> String {
        switch passes {
        case .unlimited: return "unlimited"
        case .limited(let n): return n == 1 ? "one" : "three"
        }
    }
}

// MARK: - Crazy Eights (2–5 seats — has opponents)

extension CrazyEights {
    /// Build the setup sheet for Crazy Eights from its options (R-APP-2).
    ///
    /// Presets first (from `optionsSchema`), then Options (draw mode, stock-out, match target) and House
    /// Rules (action cards) grouped separately, each with a one-line explanation (R-APP-2.1). The opponent
    /// section (R-APP-2.2) is derived from the seat range: the human takes seat 0, so opponents run
    /// `1...(maxSeats-1)`, seeded from `options.playerCount`, with bundled personas and a chosen tier.
    public static func setupSheet(
        options: CrazyEightsOptions = optionsSchema.defaults,
        personas: [AIPersona] = AIPersona.bundled,
        difficulty: DifficultyTier = .medium,
        rememberChoices: Bool = false
    ) -> SetupSheetModel {
        let presets = optionsSchema.presets.map { preset in
            SetupPreset(
                name: preset.name,
                explanation: "Starts from the \(preset.name) configuration.")
        }

        let optionControls: [SetupControl] = [
            SetupControl(
                id: "draw-mode",
                title: "Draw mode",
                explanation: "Draw until you can play, or draw one card then pass.",
                kind: .choice(
                    options: [
                        SetupOption(id: "drawUntilCanPlay", label: "Draw until playable"),
                        SetupOption(id: "drawOneThenPass", label: "Draw one, then pass"),
                    ],
                    selected: options.drawMode.rawValue)),
            SetupControl(
                id: "stock-out",
                title: "When the stock runs out",
                explanation: "Reshuffle the discards into a new stock, or end the hand.",
                kind: .choice(
                    options: [
                        SetupOption(id: "reshuffleDiscards", label: "Reshuffle discards"),
                        SetupOption(id: "endHand", label: "End the hand"),
                    ],
                    selected: options.stockOut.rawValue)),
            SetupControl(
                id: "match-target",
                title: "Match target",
                explanation: "Points a player must reach to win the match.",
                kind: .choice(
                    options: [
                        SetupOption(id: "50", label: "50 points"),
                        SetupOption(id: "100", label: "100 points"),
                        SetupOption(id: "200", label: "200 points"),
                    ],
                    selected: matchTargetID(options.matchTarget))),
        ]

        let houseRuleControls: [SetupControl] = [
            SetupControl(
                id: "action-cards",
                title: "Action cards",
                explanation: "2 draws two, Jack skips, Ace reverses — the livelier variant.",
                kind: .toggle(isOn: options.actionCards))
        ]

        // The human sits at seat 0; opponents fill the rest of the table (R-APP-2.2).
        let maxSeats = metadata.seatRange.upperBound
        let opponentRange = 1...(maxSeats - 1)
        let opponentCount = max(1, min(options.playerCount - 1, maxSeats - 1))
        let selected = Array(personas.prefix(opponentCount)).map(\.id)

        let opponents = OpponentSetup(
            supportsOpponents: true,
            opponentCountRange: opponentRange,
            opponentCount: opponentCount,
            availablePersonas: personas,
            selectedPersonaIDs: selected,
            difficulty: difficulty)

        return SetupSheetModel(
            gameID: metadata.id,
            gameName: metadata.name,
            presets: presets,
            groups: [
                SetupGroup(kind: .options, controls: optionControls),
                SetupGroup(kind: .houseRules, controls: houseRuleControls),
            ],
            opponents: opponents,
            rememberChoices: rememberChoices)
    }

    /// The choice-option id for a match-target value, snapping unusual values to the nearest offered tier.
    private static func matchTargetID(_ target: Int) -> String {
        let offered = [50, 100, 200]
        let nearest = offered.min { abs($0 - target) < abs($1 - target) } ?? 100
        return String(nearest)
    }
}
