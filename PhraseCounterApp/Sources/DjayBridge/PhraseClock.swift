import Foundation

/// Computes phrase/bar/beat position from raw elapsed time, BPM, and a
/// manually-calibrated first-downbeat offset. Stateless: recomputed fully
/// from `elapsed` on every call, so AX-driven jumps (loops, beat-jumps —
/// which TimeInterpolator already re-baselines through) are reflected with
/// no separate desync-recovery logic needed here.
public struct PhraseClock {
    public var beatsPerPhrase: Int
    public var downbeatOffsetSeconds: Double?
    public var alertWindowBeats: Int

    public init(beatsPerPhrase: Int = 32, downbeatOffsetSeconds: Double? = nil, alertWindowBeats: Int = 4) {
        self.beatsPerPhrase = beatsPerPhrase
        self.downbeatOffsetSeconds = downbeatOffsetSeconds
        self.alertWindowBeats = alertWindowBeats
    }

    public struct Position: Equatable {
        public let phraseNumber: Int
        public let barInPhrase: Int
        public let beatInBar: Int
        public let beatInPhrase: Int
        public let beatsUntilNextPhrase: Int
        public let fractionalBeat: Double
        public let secondsUntilNextPhrase: Double
        public let isInAlertWindow: Bool
    }

    public func position(elapsed: Double, rawBPM: Double, bpmPercent: Double = 0) -> Position? {
        guard let offset = downbeatOffsetSeconds, rawBPM > 0, beatsPerPhrase > 0 else { return nil }
        let bpm = Self.effectiveBPM(rawBPM: rawBPM, bpmPercent: bpmPercent)
        guard bpm > 0 else { return nil }

        let beatDuration = 60.0 / bpm
        let beatFloat = (elapsed - offset) / beatDuration
        let beatIndex = Int(beatFloat.rounded(.down))
        let fractionalBeat = beatFloat - Double(beatIndex)

        let beatInPhrase0 = floorMod(beatIndex, beatsPerPhrase)
        let beatInBar0 = floorMod(beatIndex, 4)
        let barInPhrase0 = beatInPhrase0 / 4
        let phraseIndex = floorDiv(beatIndex, beatsPerPhrase)
        let beatsUntilNext = beatsPerPhrase - beatInPhrase0

        return Position(
            phraseNumber: phraseIndex + 1,
            barInPhrase: barInPhrase0 + 1,
            beatInBar: beatInBar0 + 1,
            beatInPhrase: beatInPhrase0 + 1,
            beatsUntilNextPhrase: beatsUntilNext,
            fractionalBeat: fractionalBeat,
            secondsUntilNextPhrase: (Double(beatsUntilNext) - fractionalBeat) * beatDuration,
            isInAlertWindow: beatsUntilNext <= alertWindowBeats
        )
    }

    /// Converts djay's displayed (already pitch-adjusted) BPM back into the
    /// track's BASE/analyzed tempo, which is what beat-duration math needs here.
    ///
    /// Verified empirically (2026-07-19): djay's displayed "BPM" already reflects
    /// the pitch fader (e.g. 126.0 -> ~133.6 at +6%). But `elapsed` (from
    /// TimeInterpolator) is measured in file-content-seconds: it already advances
    /// `1 + bpmPercent/100` content-seconds per real second, to match how far
    /// into the file's audio a pitched-up track actually gets each real second.
    /// Beat positions are fixed points *within the file* at the BASE tempo's
    /// spacing (pitch doesn't rewrite the file, only playback speed). Using the
    /// displayed (pitched) BPM directly to divide file-content-seconds would
    /// double-count the pitch adjustment — confirmed live: two decks both
    /// showing BPM 127, one at 0%, one synced at +3.8%, drifted apart
    /// progressively when the displayed BPM was used unchanged. Dividing out
    /// the percentage to recover the base BPM fixed it.
    public static func effectiveBPM(rawBPM: Double, bpmPercent: Double) -> Double {
        rawBPM / (1.0 + bpmPercent / 100.0)
    }

    public static func parseBPM(_ str: String?) -> Double? {
        guard let str else { return nil }
        return Double(str.trimmingCharacters(in: .whitespaces))
    }

    public static func parsePercent(_ str: String?) -> Double {
        guard let str else { return 0 }
        let cleaned = str.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
        return Double(cleaned) ?? 0
    }
}

private func floorDiv(_ a: Int, _ n: Int) -> Int {
    let q = a / n, r = a % n
    return (r != 0 && (r < 0) != (n < 0)) ? q - 1 : q
}

private func floorMod(_ a: Int, _ n: Int) -> Int {
    let r = a % n
    return r < 0 ? r + n : r
}
