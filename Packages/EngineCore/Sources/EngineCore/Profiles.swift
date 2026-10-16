// Player profiles and AI personas — the identity a seat is occupied by (R-SESS-5).
//
// A `SeatID` (Seats.swift) names a *position* at the table; a `PlayerProfile` names *who* occupies it —
// a human's local profile or an AI persona. R-SESS-5.1 requires EngineCore to model that identity
// (id, display name, avatar, controller type), so it lives here in the pure layer as plain data: the
// engine is UI-free, so the avatar is modeled as a *reference* (an asset name or a generated-glyph
// descriptor), never a `SwiftUI.Image` — the App resolves it to pixels (design.md §1; R-BUILD-4.3).
//
// These types are pure DATA. A profile *describes* who sits in a seat and *which kind* of controller
// drives it (`.localHuman` or `.ai`); it does NOT hold a live `PlayerController` (PlayerController.swift).
// Binding a profile to a running controller when a session starts is the host/session layer's job — the
// same separation the save-snapshot in design.md §5 shows (`"seat-0", "profile": {…}, "controller": …`).
//
// `AIPersona` gives an AI seat a name, an avatar, a difficulty tier, and a SMALL, documented set of style
// parameters — `aggression` and `riskTolerance` (requirements A-6; R-AI-5.1). The concrete AI strategies
// that *consume* these to bias their evaluator are task 4.4/4.6 (design.md §4 "Personas"); here we define
// the model plus a default BUNDLED set of personas as data (R-SESS-5.2). Everything is `Codable & Sendable`
// so it round-trips into saves and crosses the host boundary unchanged (R-ENG-8.5).

import Foundation

// MARK: - ProfileID (R-SESS-5.1)

/// A stable identity for a player profile, independent of its display name or avatar (R-SESS-5.1).
///
/// A thin value type over a stable string token (e.g. a UUID string) so it stays readable in saves/logs,
/// is usable as a dictionary key, and round-trips across the host boundary. Renaming a profile or changing
/// its avatar never changes its `id` — statistics and saved seats key off the `ProfileID`, not the name.
public struct ProfileID: Hashable, Codable, Sendable {
    /// Opaque, stable profile token. Treat it as a handle rather than parsing meaning out of it.
    public let raw: String

    public init(raw: String) {
        self.raw = raw
    }

    /// Mint a fresh, unique profile id (a new UUID string). Use when creating a brand-new profile; a
    /// restored profile keeps the `raw` value it was saved with.
    public static func generate() -> ProfileID {
        ProfileID(raw: UUID().uuidString)
    }
}

extension ProfileID: CustomStringConvertible {
    public var description: String { raw }
}

// MARK: - AvatarReference (R-SESS-5.1, R-DS-6.1)

/// A UI-free reference to a profile's avatar (R-SESS-5.1).
///
/// EngineCore has no UI framework (R-BUILD-4.3), so an avatar is modeled as *data the App resolves*, not a
/// rendered image. Two forms cover current needs:
///   • `.namedPlaceholder` — the name of a bundled placeholder asset the App looks up (flagged "needs
///     production art", R-DS-6.1; see the Placeholder-art register in tasks.md).
///   • `.generatedGlyph` — a procedural avatar the App can draw from `symbol` + `tint` (an SF Symbol name
///     and a hex color), so a profile always has *some* avatar without shipping a bitmap.
/// Commissioned art later replaces placeholders by swapping the App's resolver — no engine change
/// (R-DS-4.2).
public enum AvatarReference: Hashable, Codable, Sendable {
    /// A named bundled placeholder asset the App resolves (needs production art — R-DS-6.1).
    case namedPlaceholder(String)
    /// A procedurally drawn avatar: an SF Symbol `symbol` tinted with a `tint` hex string (e.g. "#4C6EF5").
    case generatedGlyph(symbol: String, tint: String)
}

// MARK: - ControllerKind (R-SESS-5.1)

/// Which *kind* of controller drives a profile's seat (R-SESS-5.1) — plain data, not a live controller.
///
/// This mirrors the `PlayerController` conformers (PlayerController.swift) as a value: `.localHuman` is
/// driven by the UI, `.ai(persona:)` is driven by an AI strategy configured from the named persona. It is
/// deliberately NOT a reference to a running controller — the profile is a description; the session layer
/// instantiates the actual controller from this kind when a game starts (design.md §5 save snapshot).
public enum ControllerKind: Hashable, Codable, Sendable {
    /// A local human, driven by the UI (a `LocalHumanController`).
    case localHuman
    /// An AI opponent, driven by the persona named here (bound to an `AIController` at session start).
    case ai(persona: PersonaID)
}

// MARK: - PlayerProfile (R-SESS-5.1)

/// The identity occupying a seat: a stable id, a display name, an avatar, and its controller kind
/// (R-SESS-5.1).
///
/// Pure, `Codable & Sendable` data (R-ENG-8.5) describing *who* a seat is — a human's editable local
/// profile (R-SESS-5.2) or an AI persona's profile. It carries no live controller and no game state; the
/// session layer pairs a profile with a running `PlayerController` when a hand starts.
public struct PlayerProfile: Hashable, Codable, Sendable, Identifiable {
    /// Stable identity, independent of `displayName`/`avatar` (R-SESS-5.1). Statistics and saved seats
    /// key off this.
    public let id: ProfileID

    /// The name shown on the seat plate (R-SESS-5.1; R-TABLE-6.2). Editable for the local human profile
    /// (R-SESS-5.2).
    public var displayName: String

    /// A UI-free reference to the avatar the App renders (R-SESS-5.1). Placeholder art is acceptable and
    /// flagged for replacement (R-DS-6.1).
    public var avatar: AvatarReference

    /// Which kind of controller drives this profile's seat (R-SESS-5.1): a local human, or an AI persona.
    public var controllerKind: ControllerKind

    public init(
        id: ProfileID,
        displayName: String,
        avatar: AvatarReference,
        controllerKind: ControllerKind
    ) {
        self.id = id
        self.displayName = displayName
        self.avatar = avatar
        self.controllerKind = controllerKind
    }
}

extension PlayerProfile {
    /// A sensible starting profile for the local human — a fresh id, a default name, a generated glyph
    /// avatar, driven by the UI (R-SESS-5.2). The App persists edits over this interim default.
    public static func defaultLocalHuman() -> PlayerProfile {
        PlayerProfile(
            id: ProfileID.generate(),
            displayName: "Player",
            avatar: .generatedGlyph(symbol: "person.crop.circle.fill", tint: "#4C6EF5"),
            controllerKind: .localHuman)
    }
}

// MARK: - PersonaID (R-SESS-5.1)

/// A stable identity for a bundled AI persona, so a seat/profile can reference a persona by handle rather
/// than by (mutable) display name (R-SESS-5.1). A thin, `Codable`/`Hashable` value over a stable token.
public struct PersonaID: Hashable, Codable, Sendable {
    /// Opaque, stable persona token (e.g. "persona-cautious"). Treat it as a handle.
    public let raw: String

    public init(raw: String) {
        self.raw = raw
    }
}

extension PersonaID: CustomStringConvertible {
    public var description: String { raw }
}

// MARK: - DifficultyTier (R-AI-2.1)

/// The Easy/Medium/Hard tier an AI persona plays at (R-AI-2.1).
///
/// Defined here so a persona can carry its tier as data; the AIKit strategies (task 4.4/4.6) map a tier to
/// search depth / rollout budget. `CaseIterable` so the App can list all tiers for opponent setup
/// (R-APP-2.2).
public enum DifficultyTier: String, Hashable, Codable, Sendable, CaseIterable {
    case easy
    case medium
    case hard
}

// MARK: - PersonaStyle (R-AI-5.1, A-6)

/// The SMALL, documented set of style parameters that give a persona its character (R-AI-5.1; A-6).
///
/// Deliberately minimal — two normalized knobs the AIKit evaluator biases on (design.md §4 "Personas").
/// Keeping the set small and documented is an explicit requirement (A-6); new knobs need a documented
/// addition, not an ad-hoc field.
///
/// Both values are clamped to `0...1` on init so a persona can never carry an out-of-range style.
public struct PersonaStyle: Hashable, Codable, Sendable {
    /// How eagerly the persona plays to win a trick / take an offensive line, `0` (passive) … `1`
    /// (relentless). Biases the evaluator toward higher-value, higher-commitment plays as it rises.
    public let aggression: Double

    /// How much variance the persona will accept, `0` (plays the safe, high-probability line) … `1`
    /// (takes gambles for a bigger payoff). Biases the evaluator's risk weighting.
    public let riskTolerance: Double

    /// Create a style, clamping both parameters into `0...1` so a persona is always well-formed.
    public init(aggression: Double, riskTolerance: Double) {
        self.aggression = PersonaStyle.clamp(aggression)
        self.riskTolerance = PersonaStyle.clamp(riskTolerance)
    }

    private static func clamp(_ value: Double) -> Double {
        min(1.0, max(0.0, value))
    }
}

// MARK: - AIPersona (R-SESS-5.1, R-AI-5.1)

/// A named AI persona: an identity + avatar + difficulty tier + a small documented style (R-SESS-5.1,
/// R-AI-5.1; A-6).
///
/// Pure `Codable & Sendable` data. The persona *describes* an opponent; the AIKit strategy that plays as
/// this persona (reading its `tier` for budget and its `style` for evaluator bias) is task 4.4/4.6
/// (design.md §4). Avatars are generated placeholders flagged for replacement (R-DS-6.1).
public struct AIPersona: Hashable, Codable, Sendable, Identifiable {
    /// Stable identity referenced by `ControllerKind.ai(persona:)` (R-SESS-5.1).
    public let id: PersonaID

    /// The name shown on the opponent's seat plate (R-TABLE-6.2).
    public var name: String

    /// A UI-free avatar reference — a generated placeholder (needs production art, R-DS-6.1).
    public var avatar: AvatarReference

    /// The Easy/Medium/Hard tier this persona plays at (R-AI-2.1).
    public var tier: DifficultyTier

    /// The persona's small, documented style knobs (R-AI-5.1; A-6).
    public var style: PersonaStyle

    public init(
        id: PersonaID,
        name: String,
        avatar: AvatarReference,
        tier: DifficultyTier,
        style: PersonaStyle
    ) {
        self.id = id
        self.name = name
        self.avatar = avatar
        self.tier = tier
        self.style = style
    }

    /// A `PlayerProfile` for this persona, so an AI seat is described exactly like a human seat but driven
    /// by `.ai(persona:)` (R-SESS-5.1). The profile's id is derived from the persona id so it is stable.
    public var profile: PlayerProfile {
        PlayerProfile(
            id: ProfileID(raw: "profile-\(id.raw)"),
            displayName: name,
            avatar: avatar,
            controllerKind: .ai(persona: id))
    }
}

// MARK: - Bundled personas (R-SESS-5.2)

extension AIPersona {
    /// The set of built-in personas the app ships (R-SESS-5.2).
    ///
    /// A small, varied roster spanning the difficulty tiers with contrasting styles (a cautious low-risk
    /// player, a balanced one, an aggressive gambler, …), each with a generated placeholder avatar flagged
    /// for replacement (R-DS-6.1). The App surfaces these for opponent setup (R-APP-2.2); the AIKit
    /// strategies (task 4.4/4.6) read `tier` + `style` to actually play as them. This is pure data, so it
    /// can live in the engine without pulling in UI (R-BUILD-4.3).
    public static let bundled: [AIPersona] = [
        AIPersona(
            id: PersonaID(raw: "persona-rookie"),
            name: "Rookie",
            avatar: .generatedGlyph(symbol: "leaf.fill", tint: "#2F9E44"),
            tier: .easy,
            style: PersonaStyle(aggression: 0.25, riskTolerance: 0.20)),
        AIPersona(
            id: PersonaID(raw: "persona-cautious"),
            name: "Cautious Clara",
            avatar: .generatedGlyph(symbol: "tortoise.fill", tint: "#1971C2"),
            tier: .medium,
            style: PersonaStyle(aggression: 0.30, riskTolerance: 0.15)),
        AIPersona(
            id: PersonaID(raw: "persona-balanced"),
            name: "Even Steven",
            avatar: .generatedGlyph(symbol: "scalemass.fill", tint: "#5F3DC4"),
            tier: .medium,
            style: PersonaStyle(aggression: 0.50, riskTolerance: 0.50)),
        AIPersona(
            id: PersonaID(raw: "persona-aggressive"),
            name: "Reckless Rex",
            avatar: .generatedGlyph(symbol: "hare.fill", tint: "#E8590C"),
            tier: .hard,
            style: PersonaStyle(aggression: 0.90, riskTolerance: 0.85)),
        AIPersona(
            id: PersonaID(raw: "persona-shark"),
            name: "The Shark",
            avatar: .generatedGlyph(symbol: "bolt.fill", tint: "#C92A2A"),
            tier: .hard,
            style: PersonaStyle(aggression: 0.70, riskTolerance: 0.40)),
    ]

    /// Look up a bundled persona by its stable id, or `nil` if none matches (e.g. a save referencing a
    /// removed persona — the caller decides how to fall back).
    public static func bundled(withID id: PersonaID) -> AIPersona? {
        bundled.first { $0.id == id }
    }
}
