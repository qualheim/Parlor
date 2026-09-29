// Klondike Standard scoring — the single, adjustable point table (R-KLON-2.2; Q-1 NEEDS REVIEW).
//
// The "Standard" scheme follows classic Windows-Solitaire-style scoring (requirements assumption A-4).
// The exact per-move point values, the timed-play bonus formula, and any "recycle the waste" penalty are
// OPEN QUESTION Q-1 and are flagged NEEDS REVIEW in `Docs/Rules/klondike.md` §Scoring. Until they are
// confirmed by the user, the platform must not treat them as final — so every Standard value lives HERE,
// in one place, as named constants. `Klondike.apply` reads only these constants; changing a confirmed
// value later is a one-line edit with no move-logic churn (task 3.1 traceability note).
//
// The values below are a *fresh, original* point table authored for Parlor in the spirit of the classic
// scheme; they are provisional pending Q-1. The structure (which moves score, and their sign) is what
// the requirements specify; the magnitudes are the part under review.

import Foundation

/// The provisional Klondike "Standard" point table (R-KLON-2.2). **Q-1 NEEDS REVIEW** — the exact
/// magnitudes below are provisional and documented as such in `Docs/Rules/klondike.md`; the move logic
/// references these named values so a confirmed table drops in without touching `apply`.
public enum KlondikeStandardScoring {
    /// Points for turning a card from the waste up onto a tableau pile (a productive waste play).
    /// **Q-1 NEEDS REVIEW.**
    public static let wasteToTableau = 5

    /// Points for sending a card to a foundation (from waste or tableau). **Q-1 NEEDS REVIEW.**
    public static let cardToFoundation = 10

    /// Points for turning a face-down tableau card face-up (exposing it). **Q-1 NEEDS REVIEW.**
    public static let tableauCardFlipped = 5

    /// Points *lost* for moving a card back off a foundation onto the tableau (R-KLON-1.5). Stored as a
    /// negative delta. **Q-1 NEEDS REVIEW.**
    public static let foundationToTableau = -15

    /// Points *lost* for recycling the waste back into the stock (the "recycle" penalty). Applies from a
    /// pass onward per the classic scheme; stored as a negative delta. **Q-1 NEEDS REVIEW** — both the
    /// magnitude and exactly which passes it applies to are provisional.
    public static let wasteRecyclePenalty = -20

    /// The score delta for one card reaching a foundation under Standard scoring.
    public static var foundationDelta: Int { cardToFoundation }
}
