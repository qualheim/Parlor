// SetupSheetView — the real game setup sheet: presets first, Options + House Rules grouped (each control
// with a one-line explanation), opponent setup, and "Remember my choices" (R-APP-2.1, R-APP-2.2).
//
// NOTE ON BUILD: compiled by the Xcode project, not SwiftPM (design.md §1).
//
// This is the SwiftUI rendering of the PURE `SetupSheetModel` (GamesRules), which each game BUILDS from
// its options schema (Klondike / Crazy Eights builders). The view holds no per-game setup logic — it
// renders whatever descriptor the game supplied uniformly (design.md §11), tracks the player's live
// selections locally, and on "Deal" resolves them into a concrete options value the coordinator uses to
// start the real session.
//
//   • PRESETS FIRST (R-APP-2.1) — a segmented row of named presets; picking one re-seeds every control
//     to that preset's values.
//   • OPTIONS + HOUSE RULES GROUPED (R-APP-2.1) — two `Form` sections, each control a picker (`.choice`)
//     or a toggle (`.toggle`) with its one-line `explanation` shown beneath (R-APP-2.1).
//   • OPPONENT SETUP (R-APP-2.2) — count / difficulty / per-slot persona, shown only where the game has
//     opponents (Crazy Eights); solitaire (Klondike) has no opponent section.
//   • REMEMBER MY CHOICES (R-APP-2.2) — a toggle; when on, the coordinator persists the configuration.
//
// The sheet is game-agnostic; the only game-specific step is resolving the selections into the game's
// concrete options for the deal (`resolvedKlondikeOptions`), which Klondike alone needs today since it is
// the only wired table (Crazy Eights is configured here but its table lands with a later task).

import GamesUI  // SetupSheetModel, SetupGroup, SetupControl, SetupPreset, OpponentSetup, Klondike, KlondikeOptions
import SwiftUI

// MARK: - Setup sheet

/// The setup sheet for one game, presented over the library (R-APP-2). Renders the pure `SetupSheetModel`
/// and, on Deal, hands the resolved options to the window's `LibraryNavigation` coordinator.
struct SetupSheetView: View {
    /// The catalog entry being configured (drives the title + which deal path runs).
    let entry: CatalogEntry
    /// The window's navigation + deal coordinator.
    let navigation: LibraryNavigation
    /// Dismiss the sheet (Cancel or after Deal).
    let onClose: () -> Void

    /// The pure setup descriptor for this game (presets, grouped controls, opponents).
    @State private var model: SetupSheetModel

    /// The live selection for each `.choice` control, keyed by control id → selected option id.
    @State private var choiceSelections: [String: String] = [:]
    /// The live state for each `.toggle` control, keyed by control id → on/off.
    @State private var toggleStates: [String: Bool] = [:]

    /// Opponent selections (Crazy Eights): count, difficulty (personas follow the count).
    @State private var opponentCount: Int
    @State private var difficulty: DifficultyTier

    /// The "Remember my choices" flag (R-APP-2.2).
    @State private var rememberChoices: Bool

    /// Build the sheet for `entry`, seeding the descriptor + live selections from the game's builder — or
    /// from the player's remembered choices if "Remember my choices" was on last time (R-APP-2.2).
    init(entry: CatalogEntry, navigation: LibraryNavigation, onClose: @escaping () -> Void) {
        self.entry = entry
        self.navigation = navigation
        self.onClose = onClose
        // If the player asked to remember their choices, seed Klondike from the stored options.
        let remembered = RememberedSetup.klondikeOptions(for: entry.metadata.id)
        let sheet: SetupSheetModel
        if entry.metadata.id == Klondike.metadata.id, let remembered {
            sheet = Klondike.setupSheet(options: remembered, rememberChoices: true)
        } else {
            sheet = SetupSheetView.buildModel(for: entry)
        }
        _model = State(initialValue: sheet)
        _choiceSelections = State(initialValue: SetupSheetView.choiceSeed(sheet))
        _toggleStates = State(initialValue: SetupSheetView.toggleSeed(sheet))
        _opponentCount = State(initialValue: sheet.opponents.opponentCount)
        _difficulty = State(initialValue: sheet.opponents.difficulty)
        _rememberChoices = State(initialValue: sheet.rememberChoices)
    }

    var body: some View {
        NavigationStack {
            Form {
                if !model.presets.isEmpty {
                    presetSection
                }
                if let options = model.optionsGroup {
                    groupSection("Options", group: options)
                }
                if let houseRules = model.houseRulesGroup {
                    groupSection("House Rules", group: houseRules)
                }
                if model.opponents.supportsOpponents {
                    opponentSection
                }
                rememberSection
            }
            .formStyle(.grouped)
            .navigationTitle("New \(model.gameName)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onClose() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Deal") { deal() }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("setup.deal")
                }
            }
        }
        .frame(minWidth: 460, minHeight: 520)
        // A stable identifier so the accessibility UI suite can confirm it reached setup (task 7.4).
        .accessibilityIdentifier("setup.sheet")
    }

    // MARK: - Presets (R-APP-2.1)

    private var presetSection: some View {
        Section("Presets") {
            ForEach(model.presets) { preset in
                Button {
                    applyPreset(preset)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preset.name).font(.body.weight(.medium))
                        Text(preset.explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("setup.preset.\(preset.name)")
            }
        }
    }

    // MARK: - Options / House Rules (R-APP-2.1)

    /// One grouped section of controls, each rendered with its one-line explanation (R-APP-2.1).
    private func groupSection(_ title: String, group: SetupGroup) -> some View {
        Section(title) {
            ForEach(group.controls) { control in
                controlRow(control)
            }
        }
    }

    /// A single control: a picker (`.choice`) or toggle (`.toggle`), with its explanation beneath
    /// (R-APP-2.1).
    @ViewBuilder
    private func controlRow(_ control: SetupControl) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch control.kind {
            case .choice(let options, _):
                Picker(
                    control.title,
                    selection: Binding(
                        get: { choiceSelections[control.id] ?? options.first?.id ?? "" },
                        set: { choiceSelections[control.id] = $0 })
                ) {
                    ForEach(options) { option in
                        Text(option.label).tag(option.id)
                    }
                }
            case .toggle:
                Toggle(
                    control.title,
                    isOn: Binding(
                        get: { toggleStates[control.id] ?? false },
                        set: { toggleStates[control.id] = $0 }))
            }
            Text(control.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup.control.\(control.id)")
    }

    // MARK: - Opponent setup (R-APP-2.2)

    private var opponentSection: some View {
        Section("Opponents") {
            let range = model.opponents.opponentCountRange
            Stepper(
                "Opponents: \(opponentCount)", value: $opponentCount,
                in: range.lowerBound...range.upperBound)
            Text("How many AI players join the table.")
                .font(.caption).foregroundStyle(.secondary)

            Picker("Difficulty", selection: $difficulty) {
                ForEach(model.opponents.availableDifficulties, id: \.self) { tier in
                    Text(tier.rawValue.capitalized).tag(tier)
                }
            }
            Text("How strong the AI opponents play.")
                .font(.caption).foregroundStyle(.secondary)

            // The personas assigned to the chosen number of opponent slots (informational; assigned in
            // order from the bundled roster).
            if !model.opponents.availablePersonas.isEmpty {
                let assigned = model.opponents.availablePersonas.prefix(opponentCount)
                ForEach(Array(assigned.enumerated()), id: \.offset) { index, persona in
                    LabeledContent("Seat \(index + 1)", value: persona.name)
                }
            }
        }
        .accessibilityIdentifier("setup.opponents")
    }

    // MARK: - Remember choices (R-APP-2.2)

    private var rememberSection: some View {
        Section {
            Toggle("Remember my choices", isOn: $rememberChoices)
                .accessibilityIdentifier("setup.remember")
            Text("Start the next game from these settings.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    /// Apply a preset: re-seed every control to that preset's values (R-APP-2.1). For Klondike we resolve
    /// the preset options through the game's builder so control ids/values stay in sync.
    private func applyPreset(_ preset: SetupPreset) {
        if entry.metadata.id == Klondike.metadata.id,
            let presetOptions = Klondike.optionsSchema.preset(named: preset.name)?.options
        {
            let seeded = Klondike.setupSheet(options: presetOptions)
            choiceSelections = SetupSheetView.choiceSeed(seeded)
            toggleStates = SetupSheetView.toggleSeed(seeded)
        }
    }

    /// Deal the configured game (R-APP-2 → R-APP-3). Klondike resolves the selections into
    /// `KlondikeOptions` and starts the real session; other games route through the coordinator's
    /// "table coming soon" path until their table lands.
    private func deal() {
        if entry.metadata.id == Klondike.metadata.id {
            let options = resolvedKlondikeOptions()
            // Persist the configuration for next time when the player asked to remember it (R-APP-2.2).
            RememberedSetup.setKlondikeOptions(
                rememberChoices ? options : nil, for: entry.metadata.id)
            let target = entry
            onClose()
            Task { await navigation.dealKlondike(target, options: options) }
        } else if entry.metadata.id == CrazyEights.metadata.id {
            let target = entry
            let options = resolvedCrazyEightsOptions()
            onClose()
            Task { await navigation.dealCrazyEights(target, options: options) }
        } else {
            let target = entry
            onClose()
            navigation.dealUnsupported(target)
        }
    }

    /// Resolve the live Klondike selections into a concrete `KlondikeOptions` for the deal (R-APP-2.1).
    private func resolvedKlondikeOptions() -> KlondikeOptions {
        var options = KlondikeOptions()
        if let draw = choiceSelections["draw-count"] {
            options.drawCount = (draw == "three") ? .three : .one
        }
        if let scoring = choiceSelections["scoring"], let s = KlondikeScoring(rawValue: scoring) {
            options.scoring = s
        }
        if let passes = choiceSelections["stock-passes"] {
            switch passes {
            case "one": options.stockPasses = .one
            case "three": options.stockPasses = .three
            default: options.stockPasses = .unlimited
            }
        }
        options.timed = toggleStates["timed"] ?? options.timed
        options.autoFlip = toggleStates["auto-flip"] ?? options.autoFlip
        if let auto = choiceSelections["auto-move"], let a = KlondikeAutoMove(rawValue: auto) {
            options.autoMove = a
        }
        return options
    }

    /// Resolve the live Crazy Eights selections into a concrete hand configuration.
    private func resolvedCrazyEightsOptions() -> CrazyEightsOptions {
        let drawMode =
            CrazyEightsDrawMode(
                rawValue: choiceSelections["draw-mode"]
                    ?? CrazyEightsDrawMode.drawUntilCanPlay.rawValue)
            ?? .drawUntilCanPlay
        let stockOut =
            CrazyEightsStockOut(
                rawValue: choiceSelections["stock-out"]
                    ?? CrazyEightsStockOut.reshuffleDiscards.rawValue)
            ?? .reshuffleDiscards
        let target = Int(choiceSelections["match-target"] ?? "100") ?? 100
        return CrazyEightsOptions(
            playerCount: opponentCount + 1,
            drawMode: drawMode,
            stockOut: stockOut,
            matchTarget: target,
            actionCards: toggleStates["action-cards"] ?? false)
    }

    // MARK: - Descriptor building + seeding

    /// Build the pure setup descriptor for a catalog entry from the game's builder (design.md §11).
    private static func buildModel(for entry: CatalogEntry) -> SetupSheetModel {
        switch entry.metadata.id {
        case Klondike.metadata.id:
            return Klondike.setupSheet()
        case CrazyEights.metadata.id:
            return CrazyEights.setupSheet()
        default:
            // A game with no builder yet — present an empty descriptor rather than crash.
            return SetupSheetModel(
                gameID: entry.metadata.id, gameName: entry.metadata.name,
                presets: [], groups: [], opponents: .solo)
        }
    }

    /// Seed the `.choice` selections from a descriptor's current control values.
    private static func choiceSeed(_ model: SetupSheetModel) -> [String: String] {
        var seed: [String: String] = [:]
        for group in model.groups {
            for control in group.controls {
                if case .choice(_, let selected) = control.kind {
                    seed[control.id] = selected
                }
            }
        }
        return seed
    }

    /// Seed the `.toggle` states from a descriptor's current control values.
    private static func toggleSeed(_ model: SetupSheetModel) -> [String: Bool] {
        var seed: [String: Bool] = [:]
        for group in model.groups {
            for control in group.controls {
                if case .toggle(let isOn) = control.kind {
                    seed[control.id] = isOn
                }
            }
        }
        return seed
    }
}

// MARK: - Remembered setup persistence (R-APP-2.2)

/// The interim "Remember my choices" store (R-APP-2.2): persists a game's last-confirmed options so the
/// next setup sheet starts from them.
///
/// Stored as one JSON blob per game id under a UserDefaults key in the sandbox container — local-only, no
/// cloud (R-PERS-3.1), mirroring `ProfileStore` / `LibraryStateStore`. Only Klondike is resolved today
/// (the only wired table); the pattern extends to other games as their tables land. `nil` clears the
/// remembered options (the player turned the toggle off).
enum RememberedSetup {
    private static func key(_ gameID: String) -> String {
        "com.parlor.rememberedSetup.v1.\(gameID)"
    }

    /// The remembered Klondike options for `gameID`, or `nil` if none were stored / the blob is unreadable.
    static func klondikeOptions(for gameID: String, defaults: UserDefaults = .standard)
        -> KlondikeOptions?
    {
        guard let data = defaults.data(forKey: key(gameID)) else { return nil }
        return try? JSONDecoder().decode(KlondikeOptions.self, from: data)
    }

    /// Persist (or clear, when `options` is `nil`) the remembered Klondike options for `gameID`.
    static func setKlondikeOptions(
        _ options: KlondikeOptions?, for gameID: String, defaults: UserDefaults = .standard
    ) {
        guard let options else {
            defaults.removeObject(forKey: key(gameID))
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(options) {
            defaults.set(data, forKey: key(gameID))
        }
    }
}
