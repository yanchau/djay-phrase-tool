import AppKit
import SwiftUI

/// Native AppKit mouse tracking for the resize handle — added 2026-07-20
/// replacing a first attempt using SwiftUI's `DragGesture`, which grew the
/// window unreliably (shrinking worked, growing didn't). Root cause: the
/// handle lives INSIDE the very window it's resizing, so as `setFrame`
/// moves that window mid-gesture, `DragGesture`'s `.global` translation —
/// measured relative to the handle's own (moving) view — loses a stable
/// reference. `NSEvent.mouseLocation` is in screen coordinates, unaffected
/// by the window moving underneath it, which is why this is the standard
/// AppKit pattern for a custom resize grip.
private final class ResizeHandleNSView: NSView {
    private var startMouseLocation: NSPoint?
    private var startFrame: NSRect?

    // The panel has `isMovableByWindowBackground = true`, and a plain
    // NSView answers `true` to "can a mouseDown here move the window" by
    // default — so without this override, AppKit's own window-drag
    // machinery was ALSO responding to the same mouseDown/mouseDragged
    // sequence as our manual `setFrame` calls below, each fighting the
    // other for the window's frame. That's what the jitter on shrink and
    // the no-op on grow actually were (found 2026-07-20, second attempt —
    // the earlier `sizingOptions` fix addressed a real but different
    // issue and wasn't sufficient on its own).
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        startMouseLocation = NSEvent.mouseLocation
        startFrame = window?.frame
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let startFrame, let startMouseLocation else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - startMouseLocation.x
        let dy = current.y - startMouseLocation.y // AppKit screen space: y increases upward

        let minSize = window.minSize
        let newWidth = max(minSize.width, startFrame.width + dx)
        // Dragging down means the mouse's y DEcreases (screen space is
        // y-up) — the bottom-trailing handle should grow the window
        // downward/rightward while the top-left corner stays fixed.
        let newHeight = max(minSize.height, startFrame.height - dy)

        var frame = startFrame
        frame.size.width = newWidth
        frame.size.height = newHeight
        frame.origin.y = startFrame.origin.y + (startFrame.height - newHeight)
        window.setFrame(frame, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        startMouseLocation = nil
        startFrame = nil
    }
}

/// SwiftUI wrapper — sits invisibly behind the visible resize icon,
/// forwarding mouse events to the native view above.
struct ResizeHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ResizeHandleNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
