import AppKit
import SwiftUI
import DjayBridge

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // no Dock icon, no app menu — HUD-style overlay

// Launching this by double-clicking in Finder has no console attached, so the
// stderr diagnostics from findDjayPro()/checkAccessibilityPermission() below
// are invisible there — without this alert, a launch failure looked to a user
// exactly like "nothing happens," with no way to tell why short of relaunching
// from Terminal. Shown as a real alert (not just printed) so Option 2 (the
// no-Terminal path) doesn't require Terminal anyway just to see an error.
func showFatalAlertAndExit(_ message: String) -> Never {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = L.t("Impossible de démarrer", "Can't start")
    alert.informativeText = message
    alert.runModal()
    exit(1)
}

guard let djay = findDjayPro() else {
    showFatalAlertAndExit(L.t(
        "djay Pro ne semble pas ouvert. Ouvrez djay Pro, chargez un morceau sur une platine, puis relancez cette app.",
        "djay Pro doesn't appear to be running. Open djay Pro, load a track on a deck, then relaunch this app."
    ))
}
guard checkAccessibilityPermission(djay.element) else {
    showFatalAlertAndExit(L.t(
        "L'autorisation Accessibilité n'est pas accordée (ou n'a pas encore pris effet). Allez dans Réglages Système → Confidentialité et sécurité → Accessibilité, et vérifiez que PhraseCounterApp y est activé. Si la case est déjà cochée, décochez-la puis recochez-la, puis relancez cette app.",
        "Accessibility permission isn't granted (or hasn't taken effect yet). Go to System Settings → Privacy & Security → Accessibility, and make sure PhraseCounterApp is enabled there. If it's already checked, try unchecking and rechecking it, then relaunch this app."
    ))
}

let appState = AppState(djay: djay)
appState.startPolling()

// Height raised from an earlier 320 (2026-07-20) — the panel has grown a
// lot of content since that value was chosen (cue/exit countdowns, the
// Rhythm Wave, the 3-band timeline, the energy scale) and 320 was
// truncating the bottom of a deck's block by default. The panel is
// resizable regardless (see the visible resize affordance in
// ContentView), this just makes the out-of-the-box size fit without
// needing to resize immediately.
let panel = PhraseCounterPanel(contentRect: NSRect(x: 100, y: 100, width: 640, height: 520))
panel.appearance = NSAppearance(named: .darkAqua)
let hostingView = NSHostingView(rootView: ContentView().environmentObject(appState))
// Without this, resizing the (plain-AppKit, not SwiftUI-lifecycle) panel
// leaves the hosting view at its original size instead of tracking the
// window — added 2026-07-20 alongside making the panel `.resizable`.
hostingView.autoresizingMask = [.width, .height]
// Without this, NSHostingView's own intrinsic-content-size sizing fights
// any manual `setFrame` that tries to make the window LARGER than what
// SwiftUI's content currently wants — found 2026-07-20 debugging the
// resize handle: shrinking worked (with jitter, itself a symptom of this
// same fight), growing silently did nothing, both explained by the
// hosting view snapping the window back toward its own preferred size
// right after our code set it bigger.
hostingView.sizingOptions = []
panel.contentView = hostingView
panel.orderFrontRegardless()

// Ctrl+Option+1/2 — chosen as an uncommon modifier combo unlikely to collide
// with djay Pro's, a DAW's, or macOS's own shortcuts. Hardcoded for v1; a
// settings UI (future) would live in AppState + a small preferences view.
let hotkeys = HotkeyMonitor(bindings: [
    HotkeyMonitor.Binding(keyCode: 18 /* kVK_ANSI_1 */, modifiers: [.control, .option]) {
        appState.calibrateDownbeat(deck: 1)
    },
    HotkeyMonitor.Binding(keyCode: 19 /* kVK_ANSI_2 */, modifiers: [.control, .option]) {
        appState.calibrateDownbeat(deck: 2)
    },
])
hotkeys.start()

signal(SIGINT) { _ in exit(0) }

app.run()
