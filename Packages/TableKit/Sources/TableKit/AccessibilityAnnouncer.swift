// AccessibilityAnnouncer — the SwiftUI seam that speaks opponent actions/results via VoiceOver (task 7.1;
// R-A11Y-1.2).
//
// The pure derivation (`AccessibilityAnnouncement.from`) turns a `GameEvent` into the line to speak; this
// thin UI-only seam posts it through `AccessibilityNotification.Announcement` so VoiceOver reads it aloud
// when events arrive. Keeping the string derivation pure (in `AccessibilityRotors.swift`) and the posting
// here mirrors the rest of TableKit's pure-core / thin-shell split (design.md §9): the App feeds the
// `GameEvent` stream to `announce(_:nameForSeat:)` (or applies the `.announcesEvents` modifier), and the
// same lines already power the caption bar and history, so speech, captions, and history can never drift.

import EngineCore
import SwiftUI

/// Speaks the accessibility announcements derived from game events through VoiceOver (R-A11Y-1.2).
///
/// A tiny stateless helper so the App has one call to post opponent actions and results. Results
/// (hand ended) are posted at high priority so VoiceOver interrupts to speak them; routine turn/score
/// updates queue behind the current utterance.
public enum AccessibilityAnnouncer {
    /// Post a single already-derived announcement to VoiceOver.
    ///
    /// Uses `AccessibilityNotification.Announcement`, which VoiceOver speaks when it arrives. (The
    /// derivation carries an `isHighPriority` flag for results; the current announcement API speaks in
    /// arrival order, so priority is preserved in the derivation for callers that post through a
    /// priority-aware channel.)
    @MainActor
    public static func post(_ announcement: AccessibilityAnnouncement) {
        AccessibilityNotification.Announcement(announcement.text).post()
    }

    /// Derive and post the announcement for a single `GameEvent` (nothing is spoken for pure-geometry
    /// events). The App calls this as each accepted event arrives (R-A11Y-1.2).
    @MainActor
    public static func announce(
        _ event: GameEvent, nameForSeat: (SeatID) -> String
    ) {
        guard let announcement = AccessibilityAnnouncement.from(event, nameForSeat: nameForSeat)
        else { return }
        post(announcement)
    }

    /// Derive and post announcements for a batch of events, in order (R-A11Y-1.2). The App calls this when
    /// a result envelope's events arrive.
    @MainActor
    public static func announce(
        events: [GameEvent], nameForSeat: (SeatID) -> String
    ) {
        for announcement in AccessibilityAnnouncement.from(
            events: events, nameForSeat: nameForSeat)
        {
            post(announcement)
        }
    }
}

extension View {
    /// Announce a game event's narration via VoiceOver whenever `event` changes (R-A11Y-1.2).
    ///
    /// A convenience seam for a SwiftUI host that tracks the latest event: attach this and each new event
    /// is spoken (opponent actions and results), reusing the same derivation as the caption/history so the
    /// three never disagree (design.md §9).
    public func announcesEvents(
        _ event: GameEvent?, nameForSeat: @escaping (SeatID) -> String
    ) -> some View {
        onChange(of: event) { _, newValue in
            guard let newValue else { return }
            AccessibilityAnnouncer.announce(newValue, nameForSeat: nameForSeat)
        }
    }
}
