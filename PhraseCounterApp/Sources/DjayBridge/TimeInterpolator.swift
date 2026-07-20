import Foundation

public struct TimeInterpolator {
    private var lastElapsedSeconds: Double?
    private var lastRemainingSeconds: Double?
    private var lastUpdateTime: Date
    private var isPlaying: Bool = false
    private var playbackRate: Double = 1.0

    // Eased correction state. History, because both earlier attempts here
    // are instructive (2026-07-20):
    //  1. Originally: re-baseline (instant snap) on every new whole-second
    //     AX reading. Frequent (~1/s) but each snap small, bounded by
    //     AX-poll jitter (~0-125ms) — reported as small jumps.
    //  2. Added a `resyncThreshold` (0.2s) so only a genuine jump
    //     re-baselines, not routine poll jitter. Made it WORSE: gating
    //     correction behind a threshold lets real error accumulate
    //     unchecked for longer between corrections (nothing was fixing
    //     small honest drift anymore, only the rare big one), so each
    //     correction, when it did fire, closed a bigger gap — a larger
    //     jump, not a smaller one, and more visible on the continuously-
    //     rendered Rhythm Wave specifically.
    // The actual fix: keep correcting on EVERY new reading like the
    // original (nothing is left to silently drift), but never snap — a
    // decaying `elapsedCorrection`/`remainingCorrection` offset absorbs
    // whatever gap exists over `correctionDuration`, eased out. Frequent
    // AND smooth, not a tradeoff between the two. Same "ease-out, keep it
    // under ~300ms" shape recommended for any UI correction (see
    // CLAUDE.md's design-pass notes citing Emil Kowalski's animation
    // writing), applied to a numeric value instead of a view transition.
    private var elapsedCorrection: Double = 0
    private var elapsedCorrectionStart: Date?
    private var remainingCorrection: Double = 0
    private var remainingCorrectionStart: Date?
    private let correctionDuration: TimeInterval = 0.25

    public init() {
        self.lastUpdateTime = Date()
    }

    // MARK: - Update from AX poll

    public mutating func update(
        elapsedTime: String?,
        remainingTime: String?,
        isPlaying: Bool,
        bpmPercent: String?
    ) {
        let newElapsed = elapsedTime.flatMap { Self.parseTime($0) }
        let newRemaining = remainingTime.flatMap { Self.parseTime($0) }

        // If a time field disappears (view change), clear it
        if elapsedTime == nil { lastElapsedSeconds = nil }
        if remainingTime == nil { lastRemainingSeconds = nil }

        // What smooth extrapolation (baseline + any still-decaying
        // correction) currently predicts — captured before touching state
        // below.
        let predictedElapsed = interpolatedElapsed()
        let predictedRemaining = interpolatedRemaining()

        let elapsedChanged = newElapsed != nil && newElapsed != lastElapsedSeconds
        let remainingChanged = newRemaining != nil && newRemaining != lastRemainingSeconds

        // Re-baseline on every new reading — no threshold gating (see the
        // comment above `elapsedCorrection` for why that made things
        // worse). The baseline snaps to truth immediately so nothing ever
        // silently drifts; `elapsedCorrection` is what gets added back on
        // top, starting at the full (usually tiny) gap and easing to 0,
        // so the DISPLAYED value still moves smoothly rather than jumping.
        if elapsedChanged, let e = newElapsed {
            elapsedCorrection = (predictedElapsed ?? e) - e
            elapsedCorrectionStart = Date()
            lastElapsedSeconds = e
            lastUpdateTime = Date()
        }
        if remainingChanged, let r = newRemaining {
            remainingCorrection = (predictedRemaining ?? r) - r
            remainingCorrectionStart = Date()
            lastRemainingSeconds = r
            lastUpdateTime = Date()
        }

        // Always update non-time state
        self.isPlaying = isPlaying
        self.playbackRate = Self.parsePlaybackRate(bpmPercent)
    }

    // MARK: - Interpolated values

    public func interpolatedElapsed() -> Double? {
        guard let base = lastElapsedSeconds else { return nil }
        let raw: Double
        if isPlaying {
            let delta = Date().timeIntervalSince(lastUpdateTime) * playbackRate
            raw = max(0, base + delta)
        } else {
            raw = base
        }
        return max(0, raw + Self.decayedCorrection(elapsedCorrection, since: elapsedCorrectionStart, duration: correctionDuration))
    }

    public func interpolatedRemaining() -> Double? {
        guard let base = lastRemainingSeconds else { return nil }
        let raw: Double
        if isPlaying {
            let delta = Date().timeIntervalSince(lastUpdateTime) * playbackRate
            raw = max(0, base - delta)
        } else {
            raw = base
        }
        return max(0, raw + Self.decayedCorrection(remainingCorrection, since: remainingCorrectionStart, duration: correctionDuration))
    }

    /// `correction` fades from its full value to 0 over `duration`,
    /// ease-out (fast at first, settling toward the end) — a sudden
    /// correction becomes a brief, smooth catch-up instead of a jump.
    private static func decayedCorrection(_ correction: Double, since start: Date?, duration: TimeInterval) -> Double {
        guard correction != 0, let start else { return 0 }
        let t = min(1, max(0, Date().timeIntervalSince(start) / duration))
        guard t < 1 else { return 0 }
        let easedProgress = 1 - pow(1 - t, 3) // ease-out cubic
        return correction * (1 - easedProgress)
    }

    // MARK: - Formatting

    /// Formats seconds as MM:SS.m (one decimal place)
    public static func format(_ seconds: Double, negative: Bool = false) -> String {
        let total = abs(seconds)
        let mins = Int(total) / 60
        let secs = Int(total) % 60
        let tenths = Int((total - Double(Int(total))) * 10)
        let sign = negative ? "-" : ""
        return String(format: "%@%02d:%02d.~%d", sign, mins, secs, tenths)
    }

    // MARK: - Parsing

    /// Parses "MM:SS" or "-MM:SS" into positive seconds
    public static func parseTime(_ str: String) -> Double? {
        let cleaned = str.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "-", with: "")
        let parts = cleaned.split(separator: ":")
        guard parts.count == 2,
              let mins = Double(parts[0]),
              let secs = Double(parts[1]) else { return nil }
        return mins * 60.0 + secs
    }

    /// Parses BPM% string like "3.2%", "-2.0%", "0.0%" into playback rate (e.g. 1.032)
    private static func parsePlaybackRate(_ bpmPercent: String?) -> Double {
        guard let str = bpmPercent else { return 1.0 }
        let cleaned = str.replacingOccurrences(of: "%", with: "")
        guard let pct = Double(cleaned) else { return 1.0 }
        return 1.0 + (pct / 100.0)
    }
}
