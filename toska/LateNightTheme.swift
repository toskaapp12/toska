import SwiftUI

@Observable
@MainActor
class LateNightThemeManager {
    static let shared = LateNightThemeManager()
    var isLateNight: Bool
    private var timer: Timer?
    private var backgroundObserver: Any?
    private var foregroundObserver: Any?

    /// DEBUG-only preview hook (mirrors the share-card matrix env hook):
    /// `SIMCTL_CHILD_TOSKA_FORCE_NIGHT=1 simctl launch …` forces the night
    /// theme so it can be reviewed without waiting for midnight. Compiled
    /// out of Release.
    static var forcedNight: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["TOSKA_FORCE_NIGHT"] == "1"
        #else
        return false
        #endif
    }

    private init() {
        let hour = Calendar.current.component(.hour, from: Date())
        isLateNight = Self.forcedNight || hour < 5
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
        isLateNight = Self.forcedNight || hour < 5
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

    // 2026-09-16 redesign: STONE PAPER surfaces. Day values come straight from
    // the design's token table (design/toska_design_2026-09-16.dc.html,
    // oklch→sRGB); night values are derived exactly the way the web does it —
    // the [data-theme="night"] block in webapp/styles.css, converted to hex.
    // Paper = warm stone, ink = near-black plum, one ink-violet accent.
    static var background: Color      { isLateNight ? Color(hex: "14121A") : Color(hex: "FAF7F3") }
    // Posts sit directly on the paper with hairline dividers — no cards.
    static var feedBackground: Color  { isLateNight ? Color(hex: "14121A") : Color(hex: "FAF7F3") }
    static var bg2: Color             { isLateNight ? Color(hex: "201E26") : Color(hex: "F1EDE4") }
    static var cardBackground: Color  { isLateNight ? Color(hex: "14121A") : Color(hex: "FAF7F3") }
    static var card2: Color           { isLateNight ? Color(hex: "1B1921") : Color(hex: "F5F1EA") }
    static var inputBackground: Color { isLateNight ? Color(hex: "201E26") : Color(hex: "F1EDE4") }

    // Text — ink (posts, wordmark), ink2 (letter/reply bodies), meta (handles,
    // timestamps, stats words), soft (secondary UI, inactive tabs), faint
    // (tertiary/time).
    static var primaryText: Color   { isLateNight ? Color(hex: "E8E4DD") : Color(hex: "25222C") }
    static var bodyText: Color      { isLateNight ? Color(hex: "D4D0CA") : Color(hex: "33303B") }
    static var secondaryText: Color { isLateNight ? Color(hex: "93909A") : Color(hex: "5E5B66") }
    static var tertiaryText: Color  { isLateNight ? Color(hex: "6A6770") : Color(hex: "87848F") }
    static var handleText: Color    { isLateNight ? Color(hex: "9F9DA6") : Color(hex: "56535E") }

    // Dividers — hair (between posts, chrome hairlines), hair2 (stats-line
    // separators, outlined chips), dotSeparator (the "·" glyphs).
    static var divider: Color       { isLateNight ? Color(hex: "27252D") : Color(hex: "E8E3DC") }
    static var divider2: Color      { isLateNight ? Color(hex: "312F37") : Color(hex: "DFD9D1") }
    static var dotSeparator: Color  { isLateNight ? Color(hex: "5E5C65") : Color(hex: "93909B") }

    // Accent — the one ink-violet. Drives primary buttons (write pill, send,
    // post), toggles, selected states. accentText is the lighter cut used for
    // accent-coloured TEXT ("write yours", "keep reading"); onAccent is the
    // paper-toned text sitting ON accent fills.
    static var accent: Color     { isLateNight ? Color(hex: "A79AD8") : Color(hex: "3A2D5C") }
    static var accentText: Color { isLateNight ? Color(hex: "BAADEC") : Color(hex: "473871") }
    static var onAccent: Color   { isLateNight ? Color(hex: "14121A") : Color(hex: "F8F5EE") }

    // Today's-prompt band
    static var promptBg: Color      { isLateNight ? Color(hex: "211C2B") : Color(hex: "EFE8FE") }
    static var promptHair: Color    { isLateNight ? Color(hex: "302A3C") : Color(hex: "E5DEF5") }
    static var promptEyebrow: Color { isLateNight ? Color(hex: "B2A3DE") : Color(hex: "534477") }
    static var promptInk: Color     { isLateNight ? Color(hex: "E9E6EF") : Color(hex: "221D2F") }

    // Timestamp / meta tertiary, badge, and scrim
    static var timeText: Color { isLateNight ? Color(hex: "6A6770") : Color(hex: "87848F") }
    static var badge: Color    { Color.toskaWhisperPink }
    static var scrim: Color    { isLateNight ? Color.black.opacity(0.66) : Color.toskaInkBlack.opacity(0.38) }

    // Tab bar
    static var selectedPill: Color { isLateNight ? Color(hex: "1B1921") : Color(hex: "F5F1EA") }

    // Post font size bumps slightly at night
    static var postFontSize: CGFloat { isLateNight ? 16 : 15 }
}
