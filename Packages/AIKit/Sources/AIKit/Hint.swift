// Hint interface — a suggested action plus a short plain-language reason (R-AI-6.1, R-AI-6.2).
//
// A learner wants "what should I play, and why, in one sentence". `AIStrategy.hint(_:)` (Strategy.swift)
// returns this `Hint`: the suggested `AnyGameAction` and a plain-language `explanation`. Because `hint`
// reuses the same `DecisionContext` and the same toolkit as `decide`, COACH MODE reuses the identical call
// — there is no separate coach code path (R-AI-6.2).
//
// The explanation seam is intentionally generic. AIKit provides the type and a neutral default string;
// a specific game supplies the phrasing ("Playing the eight now saves it for later") when it overrides
// `hint`. To keep the pure layer free of any UI/localization framework, the explanation is a plain
// `String`; the UI may still localize it, and a game that prefers a stable key can carry a `LocalizedKey`
// (EngineCore/Views.swift) in the optional `localizedKey` field for the UI to resolve.

import Foundation
import EngineCore

// MARK: - Hint (R-AI-6.1)

/// A suggested move and a short plain-language reason for it (R-AI-6.1).
///
/// `action` is the move to suggest (type-erased, as everywhere the boundary handles actions); it is
/// expected to be one of the context's legal actions. `explanation` is a short human sentence for the
/// hint bubble / coach panel. `localizedKey`, when a game supplies one, lets the UI resolve a localized
/// string instead of the raw `explanation` (the pure layer stays UI-free — R-BUILD-4.3). `Sendable` so a
/// hint computed off the main actor can be handed back to the UI.
public struct Hint: Sendable, Hashable {
    /// The suggested action — expected to be one of `DecisionContext.legalActions` (R-AI-6.1).
    public let action: AnyGameAction

    /// A short plain-language reason shown to the learner (R-AI-6.1). Non-empty by construction of the
    /// generic default; a game supplies its own phrasing.
    public let explanation: String

    /// An optional stable, localizable key the UI may resolve instead of `explanation` (R-ENG-8.1). `nil`
    /// when the strategy only produced a raw sentence.
    public let localizedKey: LocalizedKey?

    public init(action: AnyGameAction, explanation: String, localizedKey: LocalizedKey? = nil) {
        self.action = action
        self.explanation = explanation
        self.localizedKey = localizedKey
    }

    /// The neutral explanation the default `AIStrategy.hint(_:)` attaches when a game supplies no specific
    /// phrasing (R-AI-6.1). Games override `hint` to say something more useful.
    public static let genericExplanation = "This looks like the strongest move available right now."
}
