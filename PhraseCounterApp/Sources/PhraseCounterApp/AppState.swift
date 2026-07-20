import Foundation
import DjayBridge
import Combine

/// Threading: the background queue's only job is calling the (blocking)
/// Accessibility C API off the main thread and handing back plain value
/// types. Every mutation of TimeInterpolator/PlayStateDebouncer/PhraseClock/
/// DownbeatOffsetStore happens exclusively on the main thread — both from
/// the ~8fps AX-poll callback and a separate ~60Hz render Timer (which only
/// reads). Single-threaded confinement needs no lock, unlike Reader's
/// SharedState+NSLock.
final class AppState: ObservableObject {
    @Published var deck1Info = DeckInfo()
    @Published var deck2Info = DeckInfo()
    @Published var deck1Position: PhraseClock.Position?
    @Published var deck2Position: PhraseClock.Position?
    /// Precise elapsed time, exposed only for the Volet 3 structure timeline's
    /// position marker (PhraseClock.Position already carries the beat/phrase
    /// breakdown other views need).
    @Published var deck1Elapsed: Double?
    @Published var deck2Elapsed: Double?
    /// Human-readable origin of the current downbeat calibration, for display
    /// only (e.g. "manuel", "auto (apple-music, 127.0 BPM)"). Nil = uncalibrated.
    @Published var deck1CalibrationSource: String?
    @Published var deck2CalibrationSource: String?

    /// Volet 3: structure analysis from djay's cached waveform (see
    /// DjayBridge/DjayLibraryLookup.swift). Independent of downbeat
    /// calibration — fetched for every track regardless of which
    /// calibration path applies.
    @Published var deck1StructureInfo: DjayStructureInfo?
    @Published var deck2StructureInfo: DjayStructureInfo?
    @Published var deck1CurrentSection: StructureBar.Section?
    @Published var deck2CurrentSection: StructureBar.Section?
    @Published var deck1UpcomingTransition: UpcomingTransition?
    @Published var deck2UpcomingTransition: UpcomingTransition?
    /// The DJ's own cue points (ground truth, unlike the auto-detected
    /// `UpcomingTransition` above — added alongside it, not instead of it,
    /// 2026-07-20) and the countdown/bar-number to the next one.
    @Published var deck1CuePoints: [Double] = []
    @Published var deck2CuePoints: [Double] = []
    @Published var deck1UpcomingCue: UpcomingCue?
    @Published var deck2UpcomingCue: UpcomingCue?
    /// Suggested mix-out point: the start of the next detected break
    /// (`StructureBar.Section.breakSection`) — answers a real forum
    /// request (Algoriddim community, "Automix AI break point recognition
    /// for mix out points", 2026-07-20: a DJ asking why djay finds natural
    /// mix-IN points but not mix-OUT ones) directly with the break/drop
    /// detector already built and validated for Volet 3.
    @Published var deck1UpcomingExit: UpcomingCue?
    @Published var deck2UpcomingExit: UpcomingCue?

    struct UpcomingCue {
        let secondsUntil: Double
        let barNumber: Int?
    }
    /// Current phrase's energy level, 1-10 (Mixed In Key-style scale).
    @Published var deck1EnergyLevel: Int?
    @Published var deck2EnergyLevel: Int?

    struct UpcomingTransition {
        let secondsUntil: Double
        let isPhraseAligned: Bool
        let barNumber: Int?
    }

    /// Shown on a PAUSED deck: seconds until the OTHER (playing) deck's
    /// next phrase boundary — press play on this deck now-plus-that-long
    /// to land in phrase, assuming this deck's cue point sits on its own
    /// downbeat (standard DJ practice, not verified per-track). Also the
    /// PLAYING deck's own bar number at that future moment — added
    /// 2026-07-20 at the user's request ("le numéro de barre sur lequel
    /// il faut lancer" instead of just a countdown), since a DJ watching
    /// the playing deck's own bar count go by can time the launch off
    /// that number directly rather than doing mental countdown math.
    struct PressPlayHint {
        let secondsUntil: Double
        let barNumber: Int?
        /// Which deck `barNumber` belongs to (the PLAYING one, not the
        /// paused deck this hint is shown on) — added 2026-07-20 so the
        /// text can say "mesure N du deck X" instead of a bare, ambiguous
        /// "mesure N" that didn't say whose bar count it was.
        let playingDeckNumber: Int
        /// The PAUSED deck's own bar number — the one this hint is shown
        /// on. Static while paused (it's wherever its cue point sits, not
        /// a moving position), but the user asked for both decks' bar
        /// numbers named side by side ("de chaque deck"), not just the
        /// playing one — a single labeled number wasn't what was asked.
        let pausedBarNumber: Int?
    }
    @Published var deck1PressPlayIn: PressPlayHint?
    @Published var deck2PressPlayIn: PressPlayHint?

    @Published var deck1BeatsPerPhrase: Int = 32 {
        didSet {
            guard deck1BeatsPerPhrase != oldValue else { return }
            phraseClock1.beatsPerPhrase = deck1BeatsPerPhrase
            persistPref(deck: 1)
        }
    }
    @Published var deck2BeatsPerPhrase: Int = 32 {
        didSet {
            guard deck2BeatsPerPhrase != oldValue else { return }
            phraseClock2.beatsPerPhrase = deck2BeatsPerPhrase
            persistPref(deck: 2)
        }
    }

    private let djay: DjayApp
    private var interp1 = TimeInterpolator()
    private var interp2 = TimeInterpolator()
    private var playDebounce1 = PlayStateDebouncer()
    private var playDebounce2 = PlayStateDebouncer()
    private var phraseClock1 = PhraseClock()
    private var phraseClock2 = PhraseClock()
    private var previousTitle1: String?
    private var previousArtist1: String?
    private var previousTitle2: String?
    private var previousArtist2: String?
    /// Last successfully-read (bpm, bpmPercent) pair per deck. djay's
    /// Accessibility tree is view-dependent (e.g. expanding the library
    /// panel can temporarily hide the BPM label) — without this fallback,
    /// a single missed read would blank the live position each frame and
    /// make the UI wrongly claim the track isn't calibrated, even though
    /// the actual calibration (phraseClock.downbeatOffsetSeconds) never
    /// changed. Cleared on genuine track change so a stale tempo can't
    /// leak into the next track.
    private var lastKnownTempo1: (bpm: Double, percent: Double)?
    private var lastKnownTempo2: (bpm: Double, percent: Double)?
    /// Same view-dependent-visibility problem as the tempo cache above, but
    /// for elapsed/remaining time specifically — this is the one that
    /// actually caused the "reverts to uncalibrated" bug (2026-07-20):
    /// TimeInterpolator.update() wipes its baseline the instant it's handed
    /// a `nil` elapsedTime/remainingTime, which happens whenever djay's
    /// current view hides those labels (e.g. expanding the library panel).
    /// Substituting the last-known string keeps the interpolator seeing
    /// "unchanged" input, so it just keeps extrapolating through the gap
    /// instead of going blank.
    private var lastKnownElapsedTime1: String?
    private var lastKnownRemainingTime1: String?
    private var lastKnownElapsedTime2: String?
    private var lastKnownRemainingTime2: String?
    private let store: DownbeatOffsetStore
    private let libraryLookup = DjayLibraryLookup()
    private let lookupQueue = DispatchQueue(label: "djay-library-lookup", qos: .utility)
    private var renderTimer: Timer?
    private var pollThreadRunning = false

    init(djay: DjayApp, store: DownbeatOffsetStore = DownbeatOffsetStore()) {
        self.djay = djay
        self.store = store
    }

    func startPolling() {
        pollThreadRunning = true
        let queue = DispatchQueue(label: "ax-poll", qos: .userInitiated)
        let element = djay.element
        queue.async { [weak self] in
            while self?.pollThreadRunning == true {
                let d1 = getDeckInfo(app: element, deckNumber: 1)
                let d2 = getDeckInfo(app: element, deckNumber: 2)
                DispatchQueue.main.async { self?.handleAXPoll(deck1: d1, deck2: d2) }
            }
        }

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        renderTimer = timer
    }

    func stopPolling() {
        pollThreadRunning = false
        renderTimer?.invalidate()
        renderTimer = nil
    }

    private func handleAXPoll(deck1: DeckInfo, deck2: DeckInfo) {
        var d1 = deck1
        d1.isPlaying = playDebounce1.update(isPlaying: deck1.isPlaying)
        var d2 = deck2
        d2.isPlaying = playDebounce2.update(isPlaying: deck2.isPlaying)

        let elapsedTime1 = d1.elapsedTime ?? lastKnownElapsedTime1
        let remainingTime1 = d1.remainingTime ?? lastKnownRemainingTime1
        if let e = d1.elapsedTime { lastKnownElapsedTime1 = e }
        if let r = d1.remainingTime { lastKnownRemainingTime1 = r }
        let elapsedTime2 = d2.elapsedTime ?? lastKnownElapsedTime2
        let remainingTime2 = d2.remainingTime ?? lastKnownRemainingTime2
        if let e = d2.elapsedTime { lastKnownElapsedTime2 = e }
        if let r = d2.remainingTime { lastKnownRemainingTime2 = r }

        interp1.update(elapsedTime: elapsedTime1, remainingTime: remainingTime1,
                        isPlaying: d1.isPlaying, bpmPercent: d1.bpmPercent)
        interp2.update(elapsedTime: elapsedTime2, remainingTime: remainingTime2,
                        isPlaying: d2.isPlaying, bpmPercent: d2.bpmPercent)

        if let bpm = PhraseClock.parseBPM(d1.bpm) {
            lastKnownTempo1 = (bpm, PhraseClock.parsePercent(d1.bpmPercent))
        }
        if let bpm = PhraseClock.parseBPM(d2.bpm) {
            lastKnownTempo2 = (bpm, PhraseClock.parsePercent(d2.bpmPercent))
        }

        handleTrackChange(deck: 1, info: d1)
        handleTrackChange(deck: 2, info: d2)

        deck1Info = d1
        deck2Info = d2
    }

    /// Only reacts to genuine, non-nil title/artist changes — a transient
    /// AX-read miss here would otherwise silently discard a live calibrated
    /// downbeat mid-track.
    ///
    /// Calibration priority: manual calibration (this exact artist+title
    /// previously tuned with ⌃⌥1/⌃⌥2) always wins, since it's an explicit
    /// user override. Otherwise, look up djay's own analysis (BPM + first
    /// downbeat — see DjayBridge/DjayLibraryLookup.swift) asynchronously so
    /// most tracks never need manual calibration at all.
    private func handleTrackChange(deck: Int, info: DeckInfo) {
        guard let title = info.title, let artist = info.artist else { return }
        let prevTitle = deck == 1 ? previousTitle1 : previousTitle2
        let prevArtist = deck == 1 ? previousArtist1 : previousArtist2
        guard title != prevTitle || artist != prevArtist else { return }

        if deck == 1 {
            previousTitle1 = title; previousArtist1 = artist
            lastKnownTempo1 = nil; lastKnownElapsedTime1 = nil; lastKnownRemainingTime1 = nil
        } else {
            previousTitle2 = title; previousArtist2 = artist
            lastKnownTempo2 = nil; lastKnownElapsedTime2 = nil; lastKnownRemainingTime2 = nil
        }

        // Duration disambiguates same-title+artist tracks that exist in
        // djay under several identities (e.g. a local file AND an Apple
        // Music version — see DjayBridge "Découvertes — intégration Swift
        // du Volet 3"). Best-effort: nil if djay's current view doesn't
        // expose both time labels right now, in which case lookups just
        // fall back to their pre-existing "first match" behavior.
        let durationHint = Self.durationHint(from: info)

        fetchStructure(deck: deck, title: title, artist: artist, durationHint: durationHint)
        fetchCuePoints(deck: deck, title: title, artist: artist, durationHint: durationHint)

        if let entry = store.lookup(artist: artist, title: title) {
            apply(deck: deck, offset: entry.elapsedSecondsAtDownbeat,
                  beatsPerPhrase: entry.beatsPerPhrase, source: "manuel")
            return
        }

        apply(deck: deck, offset: nil, beatsPerPhrase: nil, source: nil)
        lookupQueue.async { [weak self] in
            let result = self?.libraryLookup.lookup(artist: artist, title: title, durationHint: durationHint)
            DispatchQueue.main.async {
                guard let self else { return }
                // The deck may have moved on to a different track while the
                // (disk-bound) lookup was running — don't apply a stale result.
                let currentInfo = deck == 1 ? self.deck1Info : self.deck2Info
                guard currentInfo.title == title, currentInfo.artist == artist else { return }
                guard let result else { return }
                let origin = result.isManualGridEdit ? "djay, grille corrigée" : "djay, auto-détecté"
                self.apply(
                    deck: deck, offset: result.downbeatOffsetSeconds, beatsPerPhrase: nil,
                    source: "\(origin) (\(result.source), \(String(format: "%.1f", result.bpm)) BPM)"
                )
            }
        }
    }

    private func apply(deck: Int, offset: Double?, beatsPerPhrase: Int?, source: String?) {
        if deck == 1 {
            phraseClock1.downbeatOffsetSeconds = offset
            deck1CalibrationSource = source
            if let beatsPerPhrase { deck1BeatsPerPhrase = beatsPerPhrase }
        } else {
            phraseClock2.downbeatOffsetSeconds = offset
            deck2CalibrationSource = source
            if let beatsPerPhrase { deck2BeatsPerPhrase = beatsPerPhrase }
        }
    }

    /// Volet 3 structure (sections + transitions) — independent of downbeat
    /// calibration, so fetched unconditionally on every track change.
    private func fetchStructure(deck: Int, title: String, artist: String, durationHint: Double?) {
        if deck == 1 { deck1StructureInfo = nil } else { deck2StructureInfo = nil }
        lookupQueue.async { [weak self] in
            let result = self?.libraryLookup.lookupStructure(artist: artist, title: title, durationHint: durationHint)
            DispatchQueue.main.async {
                guard let self else { return }
                let currentInfo = deck == 1 ? self.deck1Info : self.deck2Info
                guard currentInfo.title == title, currentInfo.artist == artist else { return }
                if deck == 1 { self.deck1StructureInfo = result } else { self.deck2StructureInfo = result }
            }
        }
    }

    /// The DJ's own cue points — independent of downbeat calibration and
    /// of the structure lookup above, fetched unconditionally on every
    /// track change, same pattern as `fetchStructure`.
    private func fetchCuePoints(deck: Int, title: String, artist: String, durationHint: Double?) {
        if deck == 1 { deck1CuePoints = [] } else { deck2CuePoints = [] }
        lookupQueue.async { [weak self] in
            let result = self?.libraryLookup.lookupCuePoints(artist: artist, title: title, durationHint: durationHint)
            DispatchQueue.main.async {
                guard let self else { return }
                let currentInfo = deck == 1 ? self.deck1Info : self.deck2Info
                guard currentInfo.title == title, currentInfo.artist == artist else { return }
                if deck == 1 { self.deck1CuePoints = result ?? [] } else { self.deck2CuePoints = result ?? [] }
            }
        }
    }

    private static func durationHint(from info: DeckInfo) -> Double? {
        guard let elapsedStr = info.elapsedTime, let remainingStr = info.remainingTime,
              let elapsed = TimeInterpolator.parseTime(elapsedStr),
              let remaining = TimeInterpolator.parseTime(remainingStr)
        else { return nil }
        return elapsed + remaining
    }

    private func tick() {
        let elapsed1 = interp1.interpolatedElapsed()
        let elapsed2 = interp2.interpolatedElapsed()
        deck1Elapsed = elapsed1
        deck2Elapsed = elapsed2
        deck1Position = position(elapsed: elapsed1, info: deck1Info, clock: phraseClock1, fallback: lastKnownTempo1)
        deck2Position = position(elapsed: elapsed2, info: deck2Info, clock: phraseClock2, fallback: lastKnownTempo2)
        (deck1CurrentSection, deck1UpcomingTransition) = structureStatus(elapsed: elapsed1, info: deck1StructureInfo)
        (deck2CurrentSection, deck2UpcomingTransition) = structureStatus(elapsed: elapsed2, info: deck2StructureInfo)
        deck1EnergyLevel = currentEnergy(elapsed: elapsed1, info: deck1StructureInfo)
        deck2EnergyLevel = currentEnergy(elapsed: elapsed2, info: deck2StructureInfo)
        deck1UpcomingCue = upcomingCue(elapsed: elapsed1, cues: deck1CuePoints, info: deck1StructureInfo)
        deck2UpcomingCue = upcomingCue(elapsed: elapsed2, cues: deck2CuePoints, info: deck2StructureInfo)
        deck1UpcomingExit = upcomingExit(elapsed: elapsed1, info: deck1StructureInfo)
        deck2UpcomingExit = upcomingExit(elapsed: elapsed2, info: deck2StructureInfo)

        deck1PressPlayIn = pressPlayHint(paused: 1, playing: 2)
        deck2PressPlayIn = pressPlayHint(paused: 2, playing: 1)
    }

    /// Seconds until `playing`'s next phrase boundary, surfaced for
    /// `paused` — nil unless `paused` is actually paused, `playing` is
    /// actually playing, and both have a computable position.
    private func pressPlayHint(paused: Int, playing: Int) -> PressPlayHint? {
        let pausedInfo = paused == 1 ? deck1Info : deck2Info
        let playingInfo = playing == 1 ? deck1Info : deck2Info
        guard !pausedInfo.isPlaying, playingInfo.isPlaying,
              (paused == 1 ? deck1Position : deck2Position) != nil
        else { return nil }
        let playingPosition = playing == 1 ? deck1Position : deck2Position
        guard let secondsUntil = playingPosition?.secondsUntilNextPhrase else { return nil }

        var bar: Int?
        let playingElapsed = playing == 1 ? deck1Elapsed : deck2Elapsed
        let playingStructureInfo = playing == 1 ? deck1StructureInfo : deck2StructureInfo
        if let playingElapsed, let playingStructureInfo {
            bar = barNumber(at: playingElapsed + secondsUntil, info: playingStructureInfo)
        }

        var pausedBar: Int?
        let pausedElapsed = paused == 1 ? deck1Elapsed : deck2Elapsed
        let pausedStructureInfo = paused == 1 ? deck1StructureInfo : deck2StructureInfo
        if let pausedElapsed, let pausedStructureInfo {
            // `barNumber` returns nil before the track's first downbeat
            // (no bar is defined yet there) — correct for most uses, but
            // reported confusing here: a deck cued at/near the very start
            // (before its own downbeat, a common few-hundred-ms case) showed
            // "mesure ?" instead of the obviously-intended "mesure 1" it's
            // about to reach.
            pausedBar = barNumber(at: pausedElapsed, info: pausedStructureInfo) ?? (pausedElapsed < pausedStructureInfo.downbeatOffsetSeconds ? 1 : nil)
        }

        return PressPlayHint(secondsUntil: secondsUntil, barNumber: bar, playingDeckNumber: playing, pausedBarNumber: pausedBar)
    }

    private func structureStatus(
        elapsed: Double?, info: DjayStructureInfo?
    ) -> (StructureBar.Section?, UpcomingTransition?) {
        guard let elapsed, let info else { return (nil, nil) }
        let currentSection = info.bars.last(where: { $0.startTime <= elapsed })?.section
        let next = info.transitions
            .filter { $0.time > elapsed }
            .min(by: { $0.time < $1.time })
        let upcoming = next.map {
            UpcomingTransition(
                secondsUntil: $0.time - elapsed,
                isPhraseAligned: $0.isPhraseAligned,
                barNumber: barNumber(at: $0.time, info: info)
            )
        }
        return (currentSection, upcoming)
    }

    /// 1-indexed bar (mesure) number containing `time`, computed straight
    /// from the beatgrid (bpm + downbeat) — independent of `info.bars`,
    /// which may be empty/shorter than the full track. Nil before the
    /// first downbeat.
    /// 2026-07-20, third fix. First attempt: assumed a floating-point
    /// epsilon explained an off-by-one on a real test track — wrong, the error
    /// actually grew across the track (1 bar off at bar 17, 2 at bar 31, 0
    /// at bar 33, 6 at bar 93), which a rounding bug can't produce. Second
    /// attempt: counted raw entries in `beatTimes` instead of assuming a
    /// constant tempo — still gave the exact same wrong numbers, which is
    /// what led to the real cause (the user's own suggestion): djay's beat
    /// tracker doesn't emit an entry for every real beat, it skips ones
    /// with no clear onset (a quiet passage, a pad-only breakdown), so
    /// counting array entries undercounts across any such gap regardless
    /// of method. Fixed by using `beatIndexOffset`, which estimates the
    /// true beat number at each entry by rounding gaps to the nearest
    /// whole number of beats instead of always stepping by one.
    private func barNumber(at time: Double, info: DjayStructureInfo) -> Int? {
        guard !info.beatTimes.isEmpty, time >= info.downbeatOffsetSeconds else { return nil }
        guard let nearestBeat = Self.nearestBeatIndex(time, in: info.beatTimes) else { return nil }
        let beatsFromDownbeat = info.beatIndexOffset[nearestBeat] - info.beatIndexOffset[info.firstDownbeatIndex]
        guard beatsFromDownbeat >= 0 else { return nil }
        return beatsFromDownbeat / 4 + 1
    }

    /// Binary search for the beat closest to `time` in an ascending-sorted
    /// beat time array.
    private static func nearestBeatIndex(_ time: Double, in beatTimes: [Double]) -> Int? {
        guard !beatTimes.isEmpty else { return nil }
        var lo = 0
        var hi = beatTimes.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if beatTimes[mid] < time { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0, abs(beatTimes[lo - 1] - time) < abs(beatTimes[lo] - time) {
            return lo - 1
        }
        return lo
    }

    private func currentEnergy(elapsed: Double?, info: DjayStructureInfo?) -> Int? {
        guard let elapsed, let info else { return nil }
        return info.phraseEnergies.last(where: { $0.startTime <= elapsed })?.energyLevel
    }

    /// `info` (the structure lookup) supplies the beatgrid used for
    /// `barNumber` — cue points themselves come from a separate lookup
    /// (`deck1CuePoints`/`deck2CuePoints`), but bar-counting needs the same
    /// beat data either way, so this reuses `info` rather than duplicating
    /// a second beatgrid fetch just for cue points.
    private func upcomingCue(elapsed: Double?, cues: [Double], info: DjayStructureInfo?) -> UpcomingCue? {
        guard let elapsed else { return nil }
        guard let next = cues.filter({ $0 > elapsed }).min() else { return nil }
        let bar = info.flatMap { barNumber(at: next, info: $0) }
        return UpcomingCue(secondsUntil: next - elapsed, barNumber: bar)
    }

    /// Two kinds of suggested mix-out point — the forum request this
    /// answers (`deck1UpcomingExit`'s comment) literally asks for "Break
    /// 1, Break 2…", but the user (an actual working DJ) pointed out real
    /// DJ practice also treats a track's OUTRO as a valid, often
    /// purpose-built exit — our detector wasn't suggesting those at all
    /// until 2026-07-20:
    ///  1. Start of each SUBSTANTIAL run of consecutive `.breakSection`
    ///     bars — the moment the kick drops out. Requires at least
    ///     `minExitRunBars` (stricter than `StructureConstants`'s own
    ///     `minSectionBars` used elsewhere for badge/timeline labeling) —
    ///     added after the user found too many suggestions, several
    ///     false: this reuses the same break/drop detector already known
    ///     to be imperfect (see CLAUDE.md's that test track validation), so a
    ///     short 2-bar dip isn't worth surfacing even where it's real.
    ///  2. The single start of `.outro`, unconditionally — the outro is
    ///     definitionally the track's tail, no run-length filter needed
    ///     the way a mid-track dip does.
    /// Both feed the same combined "next one either way" countdown.
    private func upcomingExit(elapsed: Double?, info: DjayStructureInfo?) -> UpcomingCue? {
        guard let elapsed, let info, !info.bars.isEmpty else { return nil }
        let minExitRunBars = 4
        var exitTimes: [Double] = []
        var runStart: Double?
        var runLength = 0
        var sawOutro = false
        for bar in info.bars {
            if bar.section == .breakSection {
                if runStart == nil { runStart = bar.startTime }
                runLength += 1
            } else {
                if let start = runStart, runLength >= minExitRunBars { exitTimes.append(start) }
                runStart = nil
                runLength = 0
            }
            if bar.section == .outro, !sawOutro {
                exitTimes.append(bar.startTime)
                sawOutro = true
            }
        }
        if let start = runStart, runLength >= minExitRunBars { exitTimes.append(start) }

        guard let next = exitTimes.filter({ $0 > elapsed }).min() else { return nil }
        return UpcomingCue(secondsUntil: next - elapsed, barNumber: barNumber(at: next, info: info))
    }

    private func position(
        elapsed: Double?, info: DeckInfo, clock: PhraseClock, fallback: (bpm: Double, percent: Double)?
    ) -> PhraseClock.Position? {
        guard let elapsed else { return nil }
        let tempo: (bpm: Double, percent: Double)
        if let bpm = PhraseClock.parseBPM(info.bpm) {
            tempo = (bpm, PhraseClock.parsePercent(info.bpmPercent))
        } else if let fallback {
            tempo = fallback
        } else {
            return nil
        }
        return clock.position(elapsed: elapsed, rawBPM: tempo.bpm, bpmPercent: tempo.percent)
    }

    /// This instant becomes beat 1 / bar 1 / phrase 1 for the given deck.
    func calibrateDownbeat(deck: Int) {
        let elapsed = deck == 1 ? interp1.interpolatedElapsed() : interp2.interpolatedElapsed()
        guard let e = elapsed else { return }

        if deck == 1 { phraseClock1.downbeatOffsetSeconds = e; deck1CalibrationSource = "manuel" }
        else { phraseClock2.downbeatOffsetSeconds = e; deck2CalibrationSource = "manuel" }

        let info = deck == 1 ? deck1Info : deck2Info
        guard let title = info.title, let artist = info.artist else { return }
        let bpm = PhraseClock.parseBPM(info.bpm)
        store.upsert(
            artist: artist, title: title, elapsedSecondsAtDownbeat: e,
            beatsPerPhrase: deck == 1 ? deck1BeatsPerPhrase : deck2BeatsPerPhrase,
            bpmAtCalibration: bpm
        )
    }


    private func persistPref(deck: Int) {
        let info = deck == 1 ? deck1Info : deck2Info
        let clock = deck == 1 ? phraseClock1 : phraseClock2
        guard let title = info.title, let artist = info.artist,
              let offset = clock.downbeatOffsetSeconds else { return }
        store.upsert(
            artist: artist, title: title, elapsedSecondsAtDownbeat: offset,
            beatsPerPhrase: deck == 1 ? deck1BeatsPerPhrase : deck2BeatsPerPhrase
        )
    }
}
