import Foundation

/// Minimal FR/EN localization, following the macOS system language —
/// added 2026-07-20 before public release (the app's UI text had been
/// hardcoded French throughout development; this project is now shared
/// publicly for an audience that's mostly not French-speaking).
///
/// Deliberately NOT a String Catalog (`.xcstrings`): Xcode's "Extract to
/// String Catalog" that would normally populate one from source is an
/// Xcode-IDE feature, not part of the `swift build`/`swift run` toolchain
/// this project is built with — a String Catalog authored by hand would
/// still need `bundle: .module` threaded through every `Text(...)` call
/// (Swift Package resources aren't in `Bundle.main`), adding real
/// complexity for a small app like this one. A plain FR/EN switch avoids
/// both problems and needs nothing beyond what's already here to work
/// with a plain `swift run`.
///
/// Only French and English exist as options — falls back to English for
/// any other system language, matching how djay Pro itself behaves for
/// languages it doesn't localize into.
enum L {
    static let isFrench: Bool = {
        Locale.preferredLanguages.first?.hasPrefix("fr") ?? false
    }()

    /// `L.t("français", "english")` — pick whichever the system language
    /// calls for. Interpolate variables directly into each argument.
    static func t(_ fr: String, _ en: String) -> String {
        isFrench ? fr : en
    }
}
