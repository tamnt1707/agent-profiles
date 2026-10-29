import AppKit
import SwiftTerm
import SwiftUI

/// Shows a terminal view that lives in `TerminalSessions`.
///
/// The view is not made here. A container is made each time and the terminal
/// is put into it, so the same terminal can be shown again after another
/// profile was on screen.
struct EmbeddedTerminalView: NSViewRepresentable {
    let terminal: LocalProcessTerminalView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(terminal, to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        attach(terminal, to: container)
    }

    private func attach(_ terminal: LocalProcessTerminalView, to container: NSView) {
        if terminal.superview !== container {
            terminal.removeFromSuperview()
            terminal.frame = container.bounds
            terminal.autoresizingMask = [.width, .height]
            container.addSubview(terminal)
        }
        // Typing goes to the terminal as soon as it is on screen.
        DispatchQueue.main.async {
            guard let window = container.window, window.firstResponder !== terminal else { return }
            window.makeFirstResponder(terminal)
        }
    }
}
