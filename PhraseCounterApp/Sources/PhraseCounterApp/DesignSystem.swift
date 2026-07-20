import SwiftUI

/// Design tokens for the phrase-counter HUD — added 2026-07-20 as a full
/// visual pass, replacing colors/sizes that had accreted ad hoc (one hue
/// per feature as it shipped) across the session. Loosely in the spirit
/// of Emil Kowalski / "impeccable" UI craft the user asked for by name
/// (neither exists as an invocable skill here — see CLAUDE.md — so this
/// applies that sensibility by hand): a small, deliberate palette with
/// each color earning its place, a real type scale instead of ad hoc
/// sizes, consistent spacing, and — since this is a scaling HUD, not a
/// fixed document — every token is a function of `scale`, not a constant.
enum Tokens {
    // MARK: Color

    /// Deep, cool near-black — not pure black, reads as a considered
    /// surface rather than an unstyled default.
    static let background = Color(red: 0.07, green: 0.07, blue: 0.10)
    /// Card surface, one step up from `background` so the two deck blocks
    /// read as distinct panels against whatever is behind the (floating,
    /// transparent) window.
    static let surface = Color(red: 0.07, green: 0.07, blue: 0.10).opacity(0.82)

    static let textPrimary = Color(red: 0.96, green: 0.95, blue: 0.93) // warm off-white
    static let textSecondary = Color(red: 0.58, green: 0.58, blue: 0.66) // muted lavender-gray

    /// The one brand/hero accent — the phrase number, the deck picker's
    /// selection, the resize handle. Everything else below is semantic
    /// (means something specific), this is the only purely aesthetic
    /// color choice, which is why it's used sparingly.
    static let accent = Color(red: 0.73, green: 0.55, blue: 1.0) // violet

    /// Urgent — phrase boundary approaching. Universally red; not up for
    /// reinterpretation the way the others below were.
    static let alert = Color(red: 1.0, green: 0.36, blue: 0.36)
    /// "Act now" — press-play-in-sync countdown.
    static let pressPlay = Color(red: 1.0, green: 0.82, blue: 0.25)
    /// The DJ's own cue points — ground truth, distinct from anything
    /// algorithmically detected below.
    static let cue = Color(red: 0.31, green: 0.85, blue: 0.90)
    /// Suggested mix-out point AND the "break" section badge share this
    /// hue deliberately — a suggested exit *is* a detected break, same
    /// concept surfaced two ways, not two unrelated features that happen
    /// to collide.
    static let breakOrExit = Color(red: 1.0, green: 0.66, blue: 0.30)
    /// Peak energy.
    static let drop = Color(red: 0.31, green: 0.95, blue: 0.78)
    /// Intro/outro/groove read as neutral/normal states, not alerts —
    /// `textSecondary` for intro/outro, `accent` for groove (the "good,
    /// nothing-to-report" state reuses the brand color rather than adding
    /// a 7th hue).

    // MARK: Type — a real scale, not ad hoc `.caption`/`.callout` picks.
    // Sizes are BASE points at scale 1.0; every call site multiplies by
    // the live `scale` (see DeckPhraseView) so the whole HUD grows/shrinks
    // together when the window is resized, not just its outer frame.

    enum TypeSize {
        static let hero: CGFloat = 52       // the phrase number
        static let title: CGFloat = 19      // mesure/temps row
        static let headline: CGFloat = 14   // deck title, primary countdowns
        static let body: CGFloat = 12.5
        static let caption: CGFloat = 11
        static let micro: CGFloat = 9.5     // energy-scale figures, fine print
    }

    static func font(_ base: CGFloat, scale: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: base * scale, weight: weight, design: design)
    }

    // MARK: Spacing — a 4pt-based scale, also scaled live.

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    static func space(_ base: CGFloat, scale: CGFloat) -> CGFloat { base * scale }

    // MARK: Layout baseline

    /// The width one deck block was designed at (scale == 1.0). Actual
    /// available width ÷ this gives the live scale factor.
    static let baselineDeckWidth: CGFloat = 280
    /// Rough natural height of a fully-populated deck block at scale 1.0
    /// (title, phrase number, countdowns, waveform, timeline, energy,
    /// badge) — the other half of the scale computation alongside width,
    /// so a short-but-wide window doesn't scale content past what its
    /// height can actually fit.
    static let baselineContentHeight: CGFloat = 480
    static let minScale: CGFloat = 0.75
    static let maxScale: CGFloat = 2.0
}
