import SwiftUI

/// Energy level 1-10 (Mixed In Key-style), shown as 10 segments filled up
/// to the current phrase's level, colored on a green→red gradient (low
/// energy = calm/intro-like, high energy = drop/peak-like). Level itself
/// comes from `DjayStructureInfo.phraseEnergies` (DjayBridge/DjayLibraryLookup.swift,
/// ported from `volet3/analyze_track.py::energy_curve`).
struct EnergyScaleView: View {
    let level: Int? // 1...10, current phrase
    /// Single score for the whole track — added 2026-07-20 alongside the
    /// per-phrase level, matching Mixed In Key's own two-tier design (see
    /// `DjayStructureInfo.globalEnergyLevel`). Static per track, doesn't
    /// move with playback like `level` does.
    var globalLevel: Int? = nil
    var scale: CGFloat = 1.0

    private func color(for segment: Int) -> Color {
        let hue = 0.33 - (0.33 * Double(segment - 1) / 9.0) // 0.33 green -> 0.0 red
        return Color(hue: max(hue, 0), saturation: 0.75, brightness: 0.9)
    }

    var body: some View {
        // Two lines, not one — added 2026-07-20 after `globalLevel` made a
        // single HStack overflow the 280px panel width and get clipped.
        VStack(alignment: .leading, spacing: 1 * scale) {
            HStack(spacing: 6 * scale) {
                Text("Énergie")
                    .font(Tokens.font(Tokens.TypeSize.micro, scale: scale))
                    .foregroundStyle(Tokens.textSecondary)
                HStack(spacing: 2 * scale) {
                    ForEach(1...10, id: \.self) { segment in
                        RoundedRectangle(cornerRadius: 1.5 * scale)
                            .fill(segment <= (level ?? 0) ? color(for: segment) : Color.white.opacity(0.15))
                            .frame(width: 12 * scale, height: 8 * scale)
                    }
                }
                if let level {
                    Text("\(level)/10")
                        .font(Tokens.font(Tokens.TypeSize.micro, scale: scale))
                        .monospacedDigit()
                        .foregroundStyle(Tokens.textSecondary)
                }
            }
            if let globalLevel {
                Text("morceau : \(globalLevel)/10")
                    .font(Tokens.font(Tokens.TypeSize.micro, scale: scale))
                    .monospacedDigit()
                    .foregroundStyle(Tokens.textSecondary)
            }
        }
    }
}
