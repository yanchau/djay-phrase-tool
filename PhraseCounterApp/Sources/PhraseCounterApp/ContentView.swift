import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        // True responsive scaling since 2026-07-20 (an earlier version
        // just centered fixed-size content, which made growing the
        // window look like nothing happened — the content itself needs
        // to grow). One `scale` factor, computed from whichever of
        // width/height is MORE constraining so a short-but-wide (or
        // narrow-but-tall) window doesn't distort proportions — drives
        // every size in `Tokens` uniformly, never x/y independently.
        GeometryReader { geo in
            let naturalWidth = Tokens.baselineDeckWidth * 2 + Tokens.Space.lg + Tokens.Space.lg * 2
            let widthScale = geo.size.width / naturalWidth
            let heightScale = geo.size.height / Tokens.baselineContentHeight
            let scale = min(Tokens.maxScale, max(Tokens.minScale, min(widthScale, heightScale)))

            ScrollView([.horizontal, .vertical]) {
                VStack(spacing: Tokens.space(Tokens.Space.sm, scale: scale)) {
                    HStack(spacing: Tokens.space(Tokens.Space.lg, scale: scale)) {
                        DeckPhraseView(
                            scale: scale,
                            deckNumber: 1,
                            info: appState.deck1Info,
                            position: appState.deck1Position,
                            calibrationSource: appState.deck1CalibrationSource,
                            structureInfo: appState.deck1StructureInfo,
                            currentSection: appState.deck1CurrentSection,
                            upcomingTransition: appState.deck1UpcomingTransition,
                            upcomingCue: appState.deck1UpcomingCue,
                            upcomingExit: appState.deck1UpcomingExit,
                            energyLevel: appState.deck1EnergyLevel,
                            elapsed: appState.deck1Elapsed,
                            pressPlayIn: appState.deck1PressPlayIn,
                            beatsPerPhrase: $appState.deck1BeatsPerPhrase
                        )
                        DeckPhraseView(
                            scale: scale,
                            deckNumber: 2,
                            info: appState.deck2Info,
                            position: appState.deck2Position,
                            calibrationSource: appState.deck2CalibrationSource,
                            structureInfo: appState.deck2StructureInfo,
                            currentSection: appState.deck2CurrentSection,
                            upcomingTransition: appState.deck2UpcomingTransition,
                            upcomingCue: appState.deck2UpcomingCue,
                            upcomingExit: appState.deck2UpcomingExit,
                            energyLevel: appState.deck2EnergyLevel,
                            elapsed: appState.deck2Elapsed,
                            pressPlayIn: appState.deck2PressPlayIn,
                            beatsPerPhrase: $appState.deck2BeatsPerPhrase
                        )
                    }
                }
                .padding(Tokens.space(Tokens.Space.lg, scale: scale))
                .background(Tokens.surface)
                .cornerRadius(12 * scale)
                .frame(minWidth: geo.size.width, minHeight: geo.size.height)
            }
            .overlay(alignment: .bottomTrailing) {
                ZStack {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(5)
                        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 6))
                        .allowsHitTesting(false) // purely visual — ResizeHandle below owns the mouse events
                    ResizeHandle()
                        .frame(width: 30, height: 30)
                }
                .padding(8)
                .help(L.t("Glisser pour redimensionner (agrandir ou réduire)", "Drag to resize (bigger or smaller)"))
            }
            .overlay(alignment: .topTrailing) {
                // The panel is a borderless NSPanel (deliberate — no title
                // bar for a HUD), so it has no native close button either.
                // Added 2026-07-20 at the user's request: quitting
                // previously required switching to the launching Terminal
                // and Ctrl+C.
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(6)
                        .background(.black.opacity(0.75), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(8)
                .help(L.t("Quitter", "Quit"))
            }
        }
        .background(Tokens.background)
        .preferredColorScheme(.dark)
    }
}
