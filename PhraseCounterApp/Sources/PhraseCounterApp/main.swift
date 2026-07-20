import AppKit
import SwiftUI
import DjayBridge

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // no Dock icon, no app menu — HUD-style overlay

guard let djay = findDjayPro() else { exit(1) }
guard checkAccessibilityPermission(djay.element) else { exit(1) }

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
