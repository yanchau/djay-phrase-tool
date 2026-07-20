import SwiftUI

/// Shared 3-band waveform styling (bass/mid/treble stacked-layer look,
/// matched to real rekordbox screenshots from the Algoriddim forum thread
/// requesting this feature — see CLAUDE.md "Découvertes — waveform 3
/// bandes"). Used by both the scrolling Rhythm Wave and the full-track
/// structure timeline so they read as one visual language, not two
/// different color schemes for the same underlying data.
enum WaveformBandStyle {
    static let bassColor = Color(red: 0.20, green: 0.45, blue: 0.95)
    static let midColor = Color(red: 0.95, green: 0.65, blue: 0.20)
    static let trebleColor = Color(red: 0.96, green: 0.92, blue: 0.82)
    static let bassCap = 1.0
    static let midCap = 0.72
    static let trebleCap = 0.46
}
