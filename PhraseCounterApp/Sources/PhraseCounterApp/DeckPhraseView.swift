import SwiftUI
import DjayBridge

struct DeckPhraseView: View {
    let scale: CGFloat
    let deckNumber: Int
    let info: DeckInfo
    let position: PhraseClock.Position?
    let calibrationSource: String?
    let structureInfo: DjayStructureInfo?
    let currentSection: StructureBar.Section?
    let upcomingTransition: AppState.UpcomingTransition?
    let upcomingCue: AppState.UpcomingCue?
    let upcomingExit: AppState.UpcomingCue?
    let energyLevel: Int?
    let elapsed: Double?
    let pressPlayIn: AppState.PressPlayHint?
    @Binding var beatsPerPhrase: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var sectionLabel: String {
        switch currentSection {
        case .intro: return "INTRO"
        case .groove: return "GROOVE"
        case .breakSection: return "BREAK"
        case .drop: return "DROP"
        case .outro: return "OUTRO"
        case nil: return ""
        }
    }

    private var sectionColor: Color {
        switch currentSection {
        case .intro, .outro, nil: return Tokens.textSecondary
        case .groove: return Tokens.accent
        case .breakSection: return Tokens.breakOrExit
        case .drop: return Tokens.drop
        }
    }

    /// Live beat duration (content-seconds, same space as `elapsed` and
    /// every countdown's `secondsUntil`) — from the deck's own displayed
    /// BPM/BPM%, not `structureInfo.bpm` (djay's static analysis), so it
    /// tracks a pitch-bent deck correctly. Added 2026-07-20 answering a
    /// bonus request from the same forum thread as the cue-point countdown
    /// ("option to display in beats, not just seconds").
    private var beatDuration: Double? {
        guard let bpm = PhraseClock.parseBPM(info.bpm) else { return nil }
        let percent = PhraseClock.parsePercent(info.bpmPercent)
        let effective = PhraseClock.effectiveBPM(rawBPM: bpm, bpmPercent: percent)
        guard effective > 0 else { return nil }
        return 60.0 / effective
    }

    private func beatsSuffix(_ secondsUntil: Double) -> String {
        guard let beatDuration, beatDuration > 0 else { return "" }
        let beats = Int((secondsUntil / beatDuration).rounded())
        return " · \(beats) temps"
    }

    private func f(_ base: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        Tokens.font(base, scale: scale, weight: weight, design: design)
    }

    private func s(_ base: CGFloat) -> CGFloat {
        Tokens.space(base, scale: scale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: s(Tokens.Space.xs)) {
            HStack {
                Text("Deck \(deckNumber)")
                    .font(f(Tokens.TypeSize.headline, weight: .semibold))
                Spacer()
                Picker("", selection: $beatsPerPhrase) {
                    Text("16").tag(16)
                    Text("32").tag(32)
                }
                .pickerStyle(.segmented)
                .frame(width: 90 * scale)
                .labelsHidden()
            }
            // Title, artist, and where the calibration came from all
            // together right under the deck header — moved here
            // 2026-07-20 (were split across the block, calibration source
            // buried below the phrase number) at the user's request:
            // "what track is this and how do we know its grid" belongs
            // together, before the numbers that depend on it.
            Text(info.title ?? "—")
                .font(f(Tokens.TypeSize.body, weight: .medium))
                .foregroundStyle(Tokens.textPrimary)
                .lineLimit(1)
            if let artist = info.artist {
                Text(artist)
                    .font(f(Tokens.TypeSize.caption))
                    .foregroundStyle(Tokens.textSecondary)
                    .lineLimit(1)
            }
            if let calibrationSource {
                Text(calibrationSource)
                    .font(f(Tokens.TypeSize.caption))
                    .foregroundStyle(Tokens.textSecondary)
            }

            if let p = position {
                if let pressPlayIn {
                    // Both decks' bar numbers, compact — first version
                    // ("lancer le deck 2... sur la mesure... du deck 1...
                    // pour être en phase") judged too long/complicated by
                    // the user. "D{n} mesure {x}" for each side of a "→",
                    // dropping the filler words entirely.
                    let playingBar = pressPlayIn.barNumber.map { "\($0)" } ?? "?"
                    let pausedBar = pressPlayIn.pausedBarNumber.map { "\($0)" } ?? "?"
                    Text("▶ calage : D\(pressPlayIn.playingDeckNumber) mesure \(playingBar) (\(String(format: "%.1fs", pressPlayIn.secondsUntil))) → D\(deckNumber) mesure \(pausedBar)")
                        .font(f(Tokens.TypeSize.body, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Tokens.pressPlay)
                }
                HStack(alignment: .lastTextBaseline, spacing: s(6)) {
                    Text("Phrase")
                        .font(f(Tokens.TypeSize.body))
                        .foregroundStyle(Tokens.textSecondary)
                    Text("\(p.phraseNumber)")
                        .font(f(Tokens.TypeSize.hero, weight: .bold, design: .rounded))
                        .foregroundStyle(Tokens.accent)
                        .monospacedDigit()
                }
                Text("Mesure \(p.barInPhrase)/\(beatsPerPhrase / 4) · Temps \(p.beatInBar)")
                    .font(f(Tokens.TypeSize.title, design: .rounded))
                    .monospacedDigit()
                Text("↓ \(p.beatsUntilNextPhrase) temps · \(String(format: "%.1fs", p.secondsUntilNextPhrase))")
                    .font(f(Tokens.TypeSize.headline, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(p.isInAlertWindow ? Tokens.alert : Tokens.textSecondary)
                if let upcomingCue {
                    let barSuffix = upcomingCue.barNumber.map { " (mesure \($0))" } ?? ""
                    // A small colored badge, not an SF Symbol flag —
                    // reworked 2026-07-20 at the user's request to look
                    // more like djay's own lettered cue markers (A/B/C…,
                    // a small solid-colored square). Can't use djay's
                    // actual icon assets (proprietary, and this project is
                    // headed for public sharing), so this is our own
                    // shape in the same visual family, not a copy.
                    HStack(spacing: s(4)) {
                        RoundedRectangle(cornerRadius: 3 * scale)
                            .fill(Tokens.cue)
                            .frame(width: 14 * scale, height: 14 * scale)
                        Text("prochain cue : \(String(format: "%.0fs", upcomingCue.secondsUntil))\(barSuffix)\(beatsSuffix(upcomingCue.secondsUntil))")
                            .font(f(Tokens.TypeSize.body))
                            .monospacedDigit()
                    }
                    .foregroundStyle(Tokens.cue)
                }
                if let upcomingExit {
                    let barSuffix = upcomingExit.barNumber.map { " (mesure \($0))" } ?? ""
                    Text("sortie sugg. : \(String(format: "%.0fs", upcomingExit.secondsUntil))\(barSuffix)\(beatsSuffix(upcomingExit.secondsUntil))")
                        .font(f(Tokens.TypeSize.body))
                        .monospacedDigit()
                        .foregroundStyle(Tokens.breakOrExit)
                }
                if let structureInfo, !structureInfo.bars.isEmpty {
                    RhythmWaveView(info: structureInfo, elapsed: elapsed, scale: scale)
                        .padding(.top, s(Tokens.Space.xs))
                    StructureTimelineView(info: structureInfo, elapsed: elapsed, scale: scale)
                        .padding(.top, s(Tokens.Space.xs))
                    EnergyScaleView(level: energyLevel, globalLevel: structureInfo.globalEnergyLevel, scale: scale)
                        .padding(.top, s(2))
                    if !sectionLabel.isEmpty {
                        Text(sectionLabel)
                            .font(f(Tokens.TypeSize.caption, weight: .bold))
                            .foregroundStyle(sectionColor)
                    }
                    if let upcoming = upcomingTransition {
                        // Bar number leads, same reordering and for the
                        // same reason as "lancer sur la mesure N" above
                        // (2026-07-20): it's the landmark to watch for,
                        // the countdown is the backup.
                        let barPart = upcoming.barNumber.map { "mesure \($0) " } ?? ""
                        Text("prochain changement : \(barPart)(dans \(String(format: "%.0fs", upcoming.secondsUntil))\(beatsSuffix(upcoming.secondsUntil)))\(upcoming.isPhraseAligned ? "" : " (?)")")
                            .font(f(Tokens.TypeSize.body))
                            .monospacedDigit()
                            .foregroundStyle(Tokens.textPrimary)
                    }
                }
            } else {
                Text("Recherche dans la base djay…")
                    .font(f(Tokens.TypeSize.caption))
                    .foregroundStyle(Tokens.textSecondary)
                Text("(⌃⌥\(deckNumber) sur le premier kick pour caler manuellement)")
                    .font(f(Tokens.TypeSize.caption))
                    .foregroundStyle(Tokens.textSecondary)
            }
        }
        .padding(s(Tokens.Space.md))
        .frame(width: Tokens.baselineDeckWidth * scale)
        .foregroundStyle(Tokens.textPrimary)
        .background(position?.isInAlertWindow == true ? Tokens.alert.opacity(0.25) : Color.clear)
        .cornerRadius(8 * scale)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: position?.isInAlertWindow)
    }
}
