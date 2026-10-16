// SuitShapePath — vector paths for the four suit shapes (R-A11Y-3.1; used by the cached card faces).
//
// Suits ALWAYS carry a shape, so a suit is identifiable without relying on color (R-A11Y-3.1). This file
// turns a `DesignSystem.SuitShape` into a SwiftUI `Path` inside a unit rectangle (0...1 × 0...1), which
// the cached face renderer scales into pip/index positions. Keeping the geometry here (a) makes each suit
// glyph a small, testable vector, and (b) lets the face renderer draw suits at any size without a font.
//
// The paths are simple, original geometric constructions (not a licensed font): a heart from two arcs and
// a point, a diamond as a rhombus, a spade as an inverted heart with a stem, a club as three lobes with a
// stem. They read clearly at index size and at pip size.

import DesignSystem
import SwiftUI

extension SuitShape {
    /// A filled vector path for this suit shape, fitted to `rect` (R-A11Y-3.1). Original geometry, no font.
    public func path(in rect: CGRect) -> Path {
        switch self {
        case .heart: return SuitShape.heartPath(in: rect)
        case .diamond: return SuitShape.diamondPath(in: rect)
        case .spade: return SuitShape.spadePath(in: rect)
        case .club: return SuitShape.clubPath(in: rect)
        }
    }

    // MARK: - Constructions (pure geometry)

    private static func heartPath(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width
        let h = r.height
        let x = r.minX
        let y = r.minY
        p.move(to: CGPoint(x: x + w * 0.5, y: y + h * 0.30))
        // Left lobe.
        p.addCurve(
            to: CGPoint(x: x, y: y + h * 0.32),
            control1: CGPoint(x: x + w * 0.42, y: y + h * 0.08),
            control2: CGPoint(x: x, y: y + h * 0.05))
        // Down to the point.
        p.addCurve(
            to: CGPoint(x: x + w * 0.5, y: y + h),
            control1: CGPoint(x: x, y: y + h * 0.62),
            control2: CGPoint(x: x + w * 0.30, y: y + h * 0.78))
        // Up the right side.
        p.addCurve(
            to: CGPoint(x: x + w, y: y + h * 0.32),
            control1: CGPoint(x: x + w * 0.70, y: y + h * 0.78),
            control2: CGPoint(x: x + w, y: y + h * 0.62))
        // Right lobe back to top center.
        p.addCurve(
            to: CGPoint(x: x + w * 0.5, y: y + h * 0.30),
            control1: CGPoint(x: x + w, y: y + h * 0.05),
            control2: CGPoint(x: x + w * 0.58, y: y + h * 0.08))
        p.closeSubpath()
        return p
    }

    private static func diamondPath(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.midY))
        p.closeSubpath()
        return p
    }

    private static func spadePath(in r: CGRect) -> Path {
        // A spade is an inverted heart with a stem.
        var p = Path()
        let w = r.width
        let h = r.height
        let x = r.minX
        let y = r.minY
        p.move(to: CGPoint(x: x + w * 0.5, y: y + h * 0.06))
        // Down-right bulge.
        p.addCurve(
            to: CGPoint(x: x + w, y: y + h * 0.58),
            control1: CGPoint(x: x + w * 0.66, y: y + h * 0.24),
            control2: CGPoint(x: x + w, y: y + h * 0.38))
        // Right lobe curling to center.
        p.addCurve(
            to: CGPoint(x: x + w * 0.5, y: y + h * 0.66),
            control1: CGPoint(x: x + w, y: y + h * 0.80),
            control2: CGPoint(x: x + w * 0.64, y: y + h * 0.72))
        // Left lobe.
        p.addCurve(
            to: CGPoint(x: x, y: y + h * 0.58),
            control1: CGPoint(x: x + w * 0.36, y: y + h * 0.72),
            control2: CGPoint(x: x, y: y + h * 0.80))
        // Down-left bulge back to apex.
        p.addCurve(
            to: CGPoint(x: x + w * 0.5, y: y + h * 0.06),
            control1: CGPoint(x: x, y: y + h * 0.38),
            control2: CGPoint(x: x + w * 0.34, y: y + h * 0.24))
        p.closeSubpath()
        // Stem.
        var stem = Path()
        stem.move(to: CGPoint(x: x + w * 0.5, y: y + h * 0.58))
        stem.addLine(to: CGPoint(x: x + w * 0.66, y: y + h))
        stem.addLine(to: CGPoint(x: x + w * 0.34, y: y + h))
        stem.closeSubpath()
        p.addPath(stem)
        return p
    }

    private static func clubPath(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width
        let h = r.height
        let x = r.minX
        let y = r.minY
        let lobe = min(w, h) * 0.34
        // Top lobe.
        p.addEllipse(
            in: CGRect(
                x: x + w * 0.5 - lobe / 2, y: y + h * 0.04, width: lobe, height: lobe))
        // Lower-left lobe.
        p.addEllipse(
            in: CGRect(
                x: x + w * 0.06, y: y + h * 0.36, width: lobe, height: lobe))
        // Lower-right lobe.
        p.addEllipse(
            in: CGRect(
                x: x + w * 0.94 - lobe, y: y + h * 0.36, width: lobe, height: lobe))
        // Stem.
        var stem = Path()
        stem.move(to: CGPoint(x: x + w * 0.5, y: y + h * 0.5))
        stem.addLine(to: CGPoint(x: x + w * 0.64, y: y + h))
        stem.addLine(to: CGPoint(x: x + w * 0.36, y: y + h))
        stem.closeSubpath()
        p.addPath(stem)
        return p
    }
}
