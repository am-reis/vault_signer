import SwiftUI
import AppKit

/// Screen-capture blocking (spec §5.0): sets `sharingType = .none` on the
/// hosting `NSWindow`, which excludes it from screenshots, screen
/// recording, and screen sharing. Spec §5.0 lists raw-key reveal
/// screens, passphrase entry fields, import decision screens, and any
/// screen rendering a manifest in detail — since almost every screen in
/// this app past the welcome/chooser screen falls into one of those
/// categories (the key list is itself manifest detail), this is applied
/// to the whole main window's content once, plus individually to every
/// sheet (macOS presents each `.sheet()` in its own `NSWindow`, so the
/// main window's setting does not propagate to it).
struct CaptureProtected: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.sharingType = .none
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.sharingType = .none
        }
    }
}

extension View {
    func preventsScreenCapture() -> some View {
        background(CaptureProtected())
    }
}
