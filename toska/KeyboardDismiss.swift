import SwiftUI
import UIKit

// Standard "tap anywhere to dismiss the keyboard" behavior, app-wide.
//
// Implemented as a single UITapGestureRecognizer installed on the app's
// window rather than per-screen SwiftUI .onTapGesture modifiers. A
// window-level recognizer is the only approach that behaves like a normal
// iOS app everywhere at once, because:
//   - cancelsTouchesInView = false → it never swallows the tap. Buttons,
//     NavigationLinks, feed rows, and scroll gestures all still fire; the
//     recognizer just *also* ends editing.
//   - the delegate allows simultaneous recognition with every other gesture,
//     so it coexists with scroll views, the feed's pull-to-refresh drag, and
//     post taps.
//   - shouldReceive skips taps that land on a text input, so tapping a field
//     to focus it doesn't immediately resign it — only taps elsewhere lower
//     the keyboard.

private final class KeyboardDismissGesture: UITapGestureRecognizer {}

private final class KeyboardDismissDelegate: NSObject, UIGestureRecognizerDelegate {
    static let shared = KeyboardDismissDelegate()

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        // Let taps on a text field / text view fall through untouched so the
        // field can take focus normally; only dismiss when tapping elsewhere.
        var view = touch.view
        while let current = view {
            if current is UITextField || current is UITextView { return false }
            view = current.superview
        }
        return true
    }
}

extension UIApplication {
    /// Installs the window-level tap-to-dismiss-keyboard gesture once.
    @MainActor
    func installKeyboardDismissGesture() {
        let windows = connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        guard let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first else { return }
        if window.gestureRecognizers?.contains(where: { $0 is KeyboardDismissGesture }) == true {
            return // already installed
        }
        let tap = KeyboardDismissGesture(target: window, action: #selector(UIView.endEditing(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = KeyboardDismissDelegate.shared
        window.addGestureRecognizer(tap)
    }
}

extension View {
    /// Apply once at the app root. Installs the window-level keyboard-dismiss
    /// gesture on appear, retrying shortly after since the window may not be
    /// attached yet at the first onAppear.
    func dismissKeyboardOnTap() -> some View {
        onAppear {
            UIApplication.shared.installKeyboardDismissGesture()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                UIApplication.shared.installKeyboardDismissGesture()
            }
        }
    }
}
