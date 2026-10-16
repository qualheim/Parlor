// The host boundary: a Codable message envelope over an in-process transport (R-SESS-4).
//
// Everything a client (UI, AI, future remote seat) can say to the authoritative host, and everything the
// host says back, crosses ONE boundary made of two Codable message types plus a `Transport` that carries
// them (R-SESS-4.1). The whole point (R-SESS-4.2) is that the local app talks to the host exactly the way
// a network client would: it never calls host methods that hand back `State`; it sends a `ClientMessage`
// and receives `HostMessage`(s). Because both message types and everything they carry are `Codable`, a
// future network `Transport` serializes them unchanged — multiplayer becomes a transport swap, not a
// rewrite (design.md §2.9).
//
// SCOPE (task 4.1). This file builds the submit → accepted/rejected + view/events loop and its in-process
// transport. The `PlayerController` async seam and the sequential/simultaneous/out-of-turn turn models are
// task 4.2 (R-SESS-2, R-SESS-3) and are intentionally NOT built here; the boundary defined here is what
// those controllers will drive.

import Foundation

// MARK: - Action envelope (R-SESS-4.1)

/// A submitted action crossing the host boundary: the type-erased `action` plus the `seat` submitting it
/// (R-SESS-4.1).
///
/// The action is carried as `AnyGameAction` (GameDefinition.swift) so the envelope is one concrete
/// `Codable` type independent of any specific game — the generic host, which knows its `Game.Action`,
/// decodes it on receipt (design.md §2.9). Pairing the action with the acting `seat` is what lets the host
/// enforce turn order and attribute the resulting log entry (R-ENG-7.1). `Sendable` so it can be sent to
/// the host actor across the concurrency boundary (R-SESS-1.1).
public struct ActionEnvelope: Codable, Sendable, Hashable {
    /// The current schema version of this envelope; bumped on any format change (R-ENG-8.5).
    public static let currentSchemaVersion = 1

    /// The schema version this value was produced with (R-ENG-8.5).
    public let schemaVersion: Int

    /// The seat submitting the action.
    public let seat: SeatID

    /// The action being submitted, type-erased for the boundary (R-SESS-4.1, R-ENG-5.6).
    public let action: AnyGameAction

    public init(
        seat: SeatID,
        action: AnyGameAction,
        schemaVersion: Int = ActionEnvelope.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.seat = seat
        self.action = action
    }

    // Decoding tolerates an absent `schemaVersion` (treated as version 1) so older encodings decode
    // (R-ENG-8.5).
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, seat, action
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.seat = try c.decode(SeatID.self, forKey: .seat)
        self.action = try c.decode(AnyGameAction.self, forKey: .action)
    }
}

// MARK: - Result envelope (R-SESS-4.1)

/// The host's verdict on a submitted action: `accepted` (with the events the transition produced and a
/// redacted view for each addressed viewer) or `rejected` (with the typed `RuleViolation`) (R-SESS-4.1).
///
/// Modeling accepted vs rejected as two cases makes the outcome explicit at the boundary: an accepted
/// result carries the ordered `GameEvent`s (which drive animation/captions/VoiceOver/sound, R-ENG-8.1) and
/// the per-viewer redacted `views` the host chose to send (R-ENG-8.2) — never raw `State` (R-SESS-1.2). A
/// rejected result carries only the `violation`, whose `reason` is the spring-back caption (R-TABLE-4.1),
/// and signals that state did NOT change. `Codable & Sendable` so it round-trips over any transport
/// (R-SESS-4.2, R-ENG-8.5).
public enum ResultEnvelope: Codable, Sendable, Hashable {
    /// The action was legal and applied: the ordered events it produced, plus a redacted view per
    /// addressed viewer (R-SESS-4.1, R-ENG-8.1, R-ENG-8.2).
    case accepted(events: [GameEvent], views: [PlayerView])

    /// The action was illegal: state is unchanged and the reason is the spring-back caption
    /// (R-SESS-4.1, R-TABLE-4.1).
    case rejected(RuleViolation)

    // Encode with an explicit discriminator so the JSON is stable and a network transport reads it
    // unchanged (R-ENG-8.5).
    private enum CodingKeys: String, CodingKey { case kind, events, views, violation }
    private enum Kind: String, Codable { case accepted, rejected }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .accepted:
            self = .accepted(
                events: try c.decode([GameEvent].self, forKey: .events),
                views: try c.decode([PlayerView].self, forKey: .views))
        case .rejected:
            self = .rejected(try c.decode(RuleViolation.self, forKey: .violation))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .accepted(let events, let views):
            try c.encode(Kind.accepted, forKey: .kind)
            try c.encode(events, forKey: .events)
            try c.encode(views, forKey: .views)
        case .rejected(let violation):
            try c.encode(Kind.rejected, forKey: .kind)
            try c.encode(violation, forKey: .violation)
        }
    }

    /// Whether this result accepted the action (state advanced).
    public var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }
}

// MARK: - Client → host messages (R-SESS-4.1)

/// A message a client sends to the host (R-SESS-4.1).
///
/// Task 4.1 keeps this to the submit → result + view loop: `submit` an action and get a `ResultEnvelope`
/// back; `requestView` to obtain the current redacted view for a viewer. Control messages (start/undo/redo)
/// and the turn models that drive them are task 4.2, so they are deliberately not modeled here. `Codable`
/// so a network transport ships it unchanged (R-SESS-4.2).
public enum ClientMessage: Codable, Sendable, Hashable {
    /// Submit an action for the host to validate and (if legal) apply (R-SESS-4.1).
    case submit(ActionEnvelope)

    /// Ask the host for the current redacted view for `viewer` (R-SESS-4.1, R-ENG-8.2).
    case requestView(Viewer)

    private enum CodingKeys: String, CodingKey { case kind, envelope, viewer }
    private enum Kind: String, Codable { case submit, requestView }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .submit:
            self = .submit(try c.decode(ActionEnvelope.self, forKey: .envelope))
        case .requestView:
            self = .requestView(try c.decode(Viewer.self, forKey: .viewer))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .submit(let envelope):
            try c.encode(Kind.submit, forKey: .kind)
            try c.encode(envelope, forKey: .envelope)
        case .requestView(let viewer):
            try c.encode(Kind.requestView, forKey: .kind)
            try c.encode(viewer, forKey: .viewer)
        }
    }
}

// MARK: - Host → client messages (R-SESS-4.1)

/// A message the host sends back to a client (R-SESS-4.1).
///
/// A `submit` yields `result` (accepted with events + views, or rejected with a violation); a
/// `requestView` yields `viewUpdate` (a single redacted view). The host NEVER returns raw `State` — only
/// these redacted, event-carrying messages (R-SESS-1.2). `Codable` so a network transport ships it
/// unchanged (R-SESS-4.2, R-ENG-8.5).
public enum HostMessage: Codable, Sendable, Hashable {
    /// The verdict on a submitted action (R-SESS-4.1).
    case result(ResultEnvelope)

    /// A redacted view for a viewer, e.g. in reply to `requestView` (R-SESS-4.1, R-ENG-8.2).
    case viewUpdate(PlayerView)

    private enum CodingKeys: String, CodingKey { case kind, result, view }
    private enum Kind: String, Codable { case result, viewUpdate }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .result:
            self = .result(try c.decode(ResultEnvelope.self, forKey: .result))
        case .viewUpdate:
            self = .viewUpdate(try c.decode(PlayerView.self, forKey: .view))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .result(let result):
            try c.encode(Kind.result, forKey: .kind)
            try c.encode(result, forKey: .result)
        case .viewUpdate(let view):
            try c.encode(Kind.viewUpdate, forKey: .kind)
            try c.encode(view, forKey: .view)
        }
    }
}

// MARK: - Transport (R-SESS-4.2)

/// The channel a client uses to talk to the host: send a `ClientMessage`, await a `HostMessage`
/// (R-SESS-4.2).
///
/// This is the seam that makes the architecture multiplayer-ready. The local app uses a `Transport`
/// exactly the way a future network client would — request/response over Codable messages — so switching
/// to a networked game is a new `Transport` conformance, with no change to the host, rules, or UI
/// (design.md §2.9; R-SESS-2.3). In this spec the only conformance is `InProcessTransport`. `Sendable`
/// because a transport is shared across the concurrency boundary between a client and the host actor.
public protocol Transport: Sendable {
    /// Send `message` to the host and await its reply (R-SESS-4.2).
    func send(_ message: ClientMessage) async -> HostMessage
}

// MARK: - In-process transport (R-SESS-4.2)

/// The in-process `Transport`: it forwards each `ClientMessage` straight to a `GameHost` actor and returns
/// the `HostMessage` the host produces (R-SESS-4.2).
///
/// It performs no serialization — the messages already being `Codable` is what proves a network transport
/// *could* serialize them (R-SESS-4.1), while in-process delivery keeps the local app fast. It holds the
/// host so a client can be handed just a `Transport` and never see the actor directly, mirroring how a
/// network client only ever holds a socket. Generic over the game so it can hand the concrete host the
/// messages it decodes against `Game.Action`.
public struct InProcessTransport<Game: GameDefinition>: Transport {
    /// The authoritative host this transport delivers to. A client holds only the `Transport`, never this.
    private let host: GameHost<Game>

    /// Wrap a host in an in-process transport.
    public init(host: GameHost<Game>) {
        self.host = host
    }

    /// Deliver `message` to the host and return its reply (R-SESS-4.2).
    public func send(_ message: ClientMessage) async -> HostMessage {
        await host.receive(message)
    }
}
