import AppKit

/// Floating, non-activating panel — stays above djay Pro without stealing
/// focus or key-window status from it.
final class PhraseCounterPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            // `.resizable` added 2026-07-20 (drag any edge/corner to
            // resize) — borderless windows have no title bar to carry
            // resize controls, but `.resizable` alone still enables edge/
            // corner drag-resizing on a borderless window in AppKit.
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        minSize = NSSize(width: 320, height: 200)
    }

    // Needed so SwiftUI controls (the 16/32 picker) can respond to clicks.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
