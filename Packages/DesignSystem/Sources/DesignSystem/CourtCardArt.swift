// CourtCardArt — original placeholder court-card designs, flagged "needs production art" (R-DS-3.3, R-DS-6).
//
// The three court ranks (Jack, Queen, King) need pictorial designs. Traditional court imagery is a
// distribution risk (`product.md`), so the court cards SHALL use ORIGINAL designs — geometric or
// ornamental is acceptable (R-DS-3.3). Until commissioned production art lands, we ship an *original,
// geometric* placeholder for each (rank × suit): a symmetric medallion built from the suit's shape and a
// rank monogram. Every placeholder is flagged `needsProductionArt == true` so it surfaces in the
// placeholder-art register (tasks.md) and the task-8.5 audit (R-DS-6, R-DS-4.2).
//
// This file is a pure descriptor: it names the rank, the geometric motif, and the "needs production art"
// flag. The actual vector drawing (the medallion) lives in the UI layer (TableKit), keyed and cached like
// every other face (R-TABLE-2.1). No traditional/borrowed court imagery is described or drawn.

import Foundation

/// The three court (face) ranks a court-card design applies to.
public enum CourtRank: String, Sendable, Hashable, CaseIterable, Codable {
    case jack
    case queen
    case king

    /// The single-letter monogram drawn on the placeholder court design (J / Q / K).
    public var monogram: String {
        switch self {
        case .jack: return "J"
        case .queen: return "Q"
        case .king: return "K"
        }
    }
}

/// The geometric/ornamental motif family a placeholder court design is built from (all original —
/// R-DS-3.3). No figurative/traditional court imagery.
public enum CourtArtMotif: String, Sendable, Hashable, CaseIterable, Codable {
    /// A symmetric medallion: nested frames around a central suit shape and rank monogram.
    case medallion
}

/// A placeholder court-card design descriptor (R-DS-3.3). It is ORIGINAL and geometric, and always
/// carries the `needsProductionArt` flag so the placeholder audit (task 8.5) can find it (R-DS-6).
public struct CourtCardArt: Sendable, Hashable, Identifiable, Codable {
    public var id: String { "\(motif.rawValue)-\(rank.rawValue)" }
    /// The court rank this design is for.
    public let rank: CourtRank
    /// The geometric motif the design is built from.
    public let motif: CourtArtMotif
    /// Always `true` for these placeholders — surfaces "needs production art" in Settings and the
    /// task-8.5 audit (R-DS-6, R-DS-4.2). Kept as a stored flag so future production art can set it false.
    public let needsProductionArt: Bool

    public init(rank: CourtRank, motif: CourtArtMotif = .medallion, needsProductionArt: Bool = true)
    {
        self.rank = rank
        self.motif = motif
        self.needsProductionArt = needsProductionArt
    }
}

// MARK: - Built-in placeholder set (🎨 needs production art — R-DS-3.3, R-DS-6)

extension CourtCardArt {
    /// The original geometric placeholder for the Jack.
    public static let jack = CourtCardArt(rank: .jack)
    /// The original geometric placeholder for the Queen.
    public static let queen = CourtCardArt(rank: .queen)
    /// The original geometric placeholder for the King.
    public static let king = CourtCardArt(rank: .king)

    /// The placeholder court designs, one per court rank. Every entry is flagged "needs production art"
    /// (R-DS-3.3, R-DS-6); this list is what the task-8.5 audit checks.
    public static let placeholders: [CourtCardArt] = [jack, queen, king]

    /// The placeholder court design for a given court rank.
    public static func placeholder(for rank: CourtRank) -> CourtCardArt {
        placeholders.first { $0.rank == rank } ?? CourtCardArt(rank: rank)
    }
}
