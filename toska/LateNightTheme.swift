import SwiftUI

@Observable
@MainActor
class LateNightThemeManager {
    static let shared = LateNightThemeManager()
    var isLateNight: Bool
    private var timer: Timer?
    private var backgroundObserver: Any?
    private var foregroundObserver: Any?

    private init() {
        let hour = Calendar.current.component(.hour, from: Date())
        isLateNight = hour < 5
        startTimer()

        // queue: .main guarantees the callback runs on the main thread, so
        // MainActor.assumeIsolated is sound here — it asserts main-thread
        // execution at runtime and lets us touch @MainActor state directly
        // without spawning a Task hop. Same rationale for the foreground
        // observer below and the Timer block in startTimer().
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.timer?.invalidate()
                self?.timer = nil
            }
        }

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
                self?.startTimer()
            }
        }
    }

    func refresh() {
        let hour = Calendar.current.component(.hour, from: Date())
        isLateNight = hour < 5
    }

    private func startTimer() {
        timer?.invalidate()
        // FIX: reduced from 300s to 60s so the theme switches within a minute
        // of the hour changing. The previous 300s interval meant a 5-minute
        // lag at midnight before the dark theme activated.
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            // Timer is added to RunLoop.main so the block fires on the main
            // thread; assumeIsolated lets us call the @MainActor refresh()
            // directly instead of paying for a Task hop every 60 seconds.
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}

// MARK: - Environment Key
//
// FIX: LateNightTheme.background and friends are static computed properties
// that read through LateNightThemeManager.shared. SwiftUI's @Observable
// tracking only fires when a property is read inside a view's body via a
// tracked reference — reading through a static function doesn't register
// a dependency. Views using LateNightTheme.X were not reliably redrawing
// when isLateNight changed.
//
// The fix: inject LateNightThemeManager into the SwiftUI environment at the
// root of the app (.environment(LateNightThemeManager.shared) in toskaApp),
// then add a @Environment(LateNightThemeManager.self) property to any view
// that needs to react to theme changes. The static LateNightTheme properties
// still work as before for views that don't need live reactivity (e.g. one-off
// reads in non-reactive contexts), but views that need to redraw on theme
// change should read from the environment object directly.
//
// Usage in a view that needs live theme reactivity:
//
//   @Environment(LateNightThemeManager.self) private var themeManager
//
//   // Then in body:
//   .background(themeManager.isLateNight ? Color(hex: "08090a") : Color(hex: "f0f1f3"))
//
// Or use the convenience extension below:
//
//   .background(themeManager.theme.background)

extension LateNightThemeManager {
    // Convenience accessor so call sites can write themeManager.theme.background
    // instead of duplicating the color logic everywhere.
    var theme: LateNightTheme.Type { LateNightTheme.self }
}

// MARK: - LateNightTheme
//
// Static namespace for color/size tokens. These still work correctly in any
// context. Views that need guaranteed redraws on theme change should also
// hold a @Environment(LateNightThemeManager.self) reference — reading that
// property in body is what registers the SwiftUI observation dependency.

struct LateNightTheme {
    static var isLateNight: Bool {
        LateNightThemeManager.shared.isLateNight
    }

    // Backgrounds
    static var background: Color      { isLateNight ? Color(hex: "0A0B0D") : Color(hex: "EEEFF1") }
    static var bg2: Color             { isLateNight ? Color(hex: "08090A") : Color(hex: "E7E8EB") }
    static var cardBackground: Color  { isLateNight ? Color(hex: "141517") : Color(hex: "FFFFFF") }
    static var card2: Color           { isLateNight ? Color(hex: "1C1E21") : Color(hex: "F6F7F8") }
    static var inputBackground: Color { isLateNight ? Color(hex: "1B1D1F") : Color(hex: "E9EBEE") }

    // Text
    static var primaryText: Color   { isLateNight ? Color(hex: "E6E7EA") : Color(hex: "14130F") }
    static var secondaryText: Color { isLateNight ? Color(hex: "82868D") : Color(hex: "8A8D96") }
    static var tertiaryText: Color  { isLateNight ? Color(hex: "5C5F66") : Color(hex: "A9ACB4") }
    static var handleText: Color    { isLateNight ? Color(hex: "B6B9BE") : Color(hex: "2A2C32") }

    // Dividers
    static var divider: Color { isLateNight ? Color(hex: "222427") : Color(hex: "E2E4E8") }

    // Accent — theme-aware muted blue (handles, primary buttons, active states)
    static var accent: Color { isLateNight ? Color(hex: "9AA1B2") : Color(hex: "828AA0") }

    // Timestamp / meta tertiary, badge, and scrim
    static var timeText: Color { isLateNight ? Color(hex: "4E5157") : Color(hex: "B7BAC1") }
    static var badge: Color    { Color(hex: "C47A8A") }
    static var scrim: Color    { isLateNight ? Color.black.opacity(0.66) : Color(hex: "14130F").opacity(0.38) }

    // Tab bar
    static var selectedPill: Color { isLateNight ? Color(hex: "1c1e1f") : Color(hex: "dfe1e5").opacity(0.6) }

    // Post font size bumps slightly at night
    static var postFontSize: CGFloat { isLateNight ? 16 : 15 }
}
