// The setup-sheet model — a pure description of a game's configuration screen (R-APP-2).
//
// The setup sheet lists PRESETS FIRST, then OPTIONS and HOUSE RULES grouped SEPARATELY, each item with a
// one-line explanation (R-APP-2.1); plus OPPONENT SETUP — count, persona, difficulty — and a "Remember my
// choices" toggle (R-APP-2.2). This file models all of that as pure, `Sendable` value types so the whole
// sheet layout is unit-testable headless; the App renders standard SwiftUI controls (pickers, toggles,
// steppers) from the model (design.md §10) and persists the remembered choices via the settings/store
// layer.
//
// WHY A DESCRIPTOR, NOT A FORM. Each game's options differ (Klondike's draw/scoring vs Crazy Eights'
// player count/action cards), so the sheet is modeled as a game-agnostic DESCRIPTOR — named groups of
// named controls, each control carrying its one-line explanation and its current value — that a game
// BUILDS from its `optionsSchema` (Klondike/CrazyEights builders below). The App renders any descriptor
// uniformly; adding a game means writing its builder, not new UI (R-ENG-5.6 spirit; design.md §11).
//
// OPTIONS vs HOUSE RULES (R-APP-2.1). "Options" are the core variant choices that define how the game is
// played (draw count, scoring, player count). "House rules" are the softer, optional tweaks layered on top
// (auto-flip, auto-move, action-cards). Each game's builder classifies its own controls into the two
// groups; the model just keeps them separate so the sheet can render them under distinct headers.

import EngineCore
import Foundation

// MARK: - Setup control (one configurable item with a one-line explanation)

/// One configurable control on the setup sheet: a titled choice/toggle with a one-line explanation and
/// its current value (R-APP-2.1).
///
/// Game-agnostic: a control is either a `.choice` among named cases (rendered as a picker/segmented
/// control) or a `.toggle` (rendered as a switch). Each carries the `explanation` R-APP-2.1 requires —
/// one line telling the player what the option does. The `value`/`isOn` fields hold the CURRENT selection
/// so the sheet is a faithful snapshot the App binds to; the game's builder sets them from a concrete
/// options value.
public struct SetupControl: Hashable, Sendable, Identifiable {
    /// The kind of control and its state.
    public enum Kind: Hashable, Sendable {
        /// A choice among named options; `selected` is the id of the chosen option.
        case choice(options: [SetupOption], selected: String)
        /// An on/off toggle; `isOn` is its current state.
        case toggle(isOn: Bool)
    }

    /// A stable id for this control within its group (e.g. "draw-count").
    public let id: String
    /// The control's display title (e.g. "Draw count").
    public let title: String
    /// The one-line explanation R-APP-2.1 requires (e.g. "How many cards you turn from the stock").
    public let explanation: String
    /// The control's kind + current state.
    public let kind: Kind

    public init(id: String, title: String, explanation: String, kind: Kind) {
        self.id = id
        self.title = title
        self.explanation = explanation
        self.kind = kind
    }
}

/// One selectable option within a `.choice` control (e.g. "Draw 1" / "Draw 3").
public struct SetupOption: Hashable, Sendable, Identifiable {
    /// Stable option id (e.g. "one").
    public let id: String
    /// Display label (e.g. "Draw 1").
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

// MARK: - Setup group (options vs house rules)

/// A titled group of setup controls — used to keep Options and House Rules separate (R-APP-2.1).
public struct SetupGroup: Hashable, Sendable, Identifiable {
    /// Which kind of group this is, so the sheet renders the two under distinct headers (R-APP-2.1).
    public enum Kind: String, Hashable, Sendable {
        /// Core variant choices that define how the game is played.
        case options
        /// Softer, optional tweaks layered on top of the core rules.
        case houseRules
    }

    /// The group kind (options or house rules).
    public let kind: Kind
    /// The controls in this group, in display order.
    public let controls: [SetupControl]

    /// Identify a group by its kind.
    public var id: String { kind.rawValue }

    public init(kind: Kind, controls: [SetupControl]) {
        self.kind = kind
        self.controls = controls
    }
}

// MARK: - Preset (listed first)

/// A named preset shown first on the setup sheet (R-APP-2.1) — a display name over a preset id the App
/// applies to the game's options.
public struct SetupPreset: Hashable, Sendable, Identifiable {
    /// The preset name, which doubles as its id (preset names are unique within a game's schema).
    public let name: String
    /// A one-line explanation of what the preset selects (R-APP-2.1).
    public let explanation: String

    public var id: String { name }

    public init(name: String, explanation: String) {
        self.name = name
        self.explanation = explanation
    }
}

// MARK: - Opponent setup (R-APP-2.2)

/// The opponent setup section: how many opponents, which personas, and the difficulty (R-APP-2.2).
///
/// `opponentCount` is the number of AI opponents (the local human is always seat 0); `availablePersonas`
/// are the bundled personas the player picks from (EngineCore `AIPersona.bundled`); `selectedPersonaIDs`
/// are the chosen personas per opponent slot; `difficulty` is the tier applied. A solo game (seat range
/// `1...1`, e.g. Klondike) has `supportsOpponents == false` and an empty opponent section. Pure so the
/// sheet is fully testable.
public struct OpponentSetup: Hashable, Sendable {
    /// Whether this game has opponents at all (false for solitaire, R-APP-2.2 only applies where opponents
    /// exist).
    public let supportsOpponents: Bool
    /// The allowed number of AI opponents, inclusive (e.g. 1...4 for a 2–5 seat game). Empty range when
    /// the game has no opponents.
    public let opponentCountRange: ClosedRange<Int>
    /// The chosen number of AI opponents.
    public var opponentCount: Int
    /// The bundled personas the player may assign (R-APP-2.2; R-SESS-5.2).
    public let availablePersonas: [AIPersona]
    /// The persona chosen for each opponent slot (ids into `availablePersonas`).
    public var selectedPersonaIDs: [PersonaID]
    /// The difficulty tier applied to the opponents (R-APP-2.2).
    public var difficulty: DifficultyTier
    /// The difficulty tiers offered (all tiers).
    public let availableDifficulties: [DifficultyTier]

    public init(
        supportsOpponents: Bool,
        opponentCountRange: ClosedRange<Int>,
        opponentCount: Int,
        availablePersonas: [AIPersona],
        selectedPersonaIDs: [PersonaID],
        difficulty: DifficultyTier,
        availableDifficulties: [DifficultyTier] = DifficultyTier.allCases
    ) {
        self.supportsOpponents = supportsOpponents
        self.opponentCountRange = opponentCountRange
        self.opponentCount = opponentCount
        self.availablePersonas = availablePersonas
        self.selectedPersonaIDs = selectedPersonaIDs
        self.difficulty = difficulty
        self.availableDifficulties = availableDifficulties
    }

    /// The opponent section for a solo game — no opponents (R-APP-2.2 applies only where opponents exist).
    public static var solo: OpponentSetup {
        OpponentSetup(
            supportsOpponents: false,
            opponentCountRange: 0...0,
            opponentCount: 0,
            availablePersonas: [],
            selectedPersonaIDs: [],
            difficulty: .medium)
    }
}

// MARK: - SetupSheetModel (R-APP-2)

/// The complete pure description of a game's setup sheet (R-APP-2): presets first, then options + house
/// rules grouped separately (each with a one-line explanation), opponent setup, and a remember-choices
/// flag.
///
/// A game builds this from its `optionsSchema` + metadata (see the Klondike / Crazy Eights builders). The
/// App renders it with standard controls and, when `rememberChoices` is on, persists the chosen preset /
/// options / opponents via the settings-store layer so the next setup starts from them (R-APP-2.2).
public struct SetupSheetModel: Sendable {
    /// The game's id (for persistence keys and applying choices).
    public let gameID: String
    /// The game's display name.
    public let gameName: String
    /// The named presets, shown FIRST (R-APP-2.1).
    public let presets: [SetupPreset]
    /// The "Options" and "House Rules" groups, kept separate (R-APP-2.1).
    public let groups: [SetupGroup]
    /// The opponent setup section (R-APP-2.2).
    public var opponents: OpponentSetup
    /// The "Remember my choices" flag (R-APP-2.2). When on, the App persists the configuration.
    public var rememberChoices: Bool

    public init(
        gameID: String,
        gameName: String,
        presets: [SetupPreset],
        groups: [SetupGroup],
        opponents: OpponentSetup,
        rememberChoices: Bool = false
    ) {
        self.gameID = gameID
        self.gameName = gameName
        self.presets = presets
        self.groups = groups
        self.opponents = opponents
        self.rememberChoices = rememberChoices
    }

    /// The Options group, if present.
    public var optionsGroup: SetupGroup? {
        groups.first { $0.kind == .options }
    }

    /// The House Rules group, if present.
    public var houseRulesGroup: SetupGroup? {
        groups.first { $0.kind == .houseRules }
    }
}
