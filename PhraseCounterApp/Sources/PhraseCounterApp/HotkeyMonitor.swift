import AppKit

/// Global keyboard shortcuts for downbeat calibration — must fire even when
/// djay Pro (or another app) has focus. Verified empirically: NSEvent's
/// global monitor fires for a process already Accessibility-trusted
/// (AXIsProcessTrusted), the same trust already granted to Terminal.app for
/// AX-tree reading — no separate "Input Monitoring" permission needed.
final class HotkeyMonitor {
    struct Binding {
        let keyCode: UInt16
        let modifiers: NSEvent.ModifierFlags
        let action: () -> Void
    }

    private let bindings: [Binding]
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let relevantFlags: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    init(bindings: [Binding]) {
        self.bindings = bindings
    }

    func start() {
        // Fires while another app is frontmost.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.dispatch(event)
        }
        // Fires while this app's own panel happens to be key (global monitors
        // alone only see events bound for OTHER apps).
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.dispatch(event)
            return event // never swallow — don't interfere with normal panel interaction
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }

    private func dispatch(_ event: NSEvent) {
        let eventMods = event.modifierFlags.intersection(relevantFlags)
        for binding in bindings where binding.keyCode == event.keyCode && eventMods == binding.modifiers {
            // Defensive: don't assume which thread delivers this callback.
            DispatchQueue.main.async { binding.action() }
        }
    }
}
