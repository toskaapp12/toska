import SwiftUI

// MARK: - Toska Design System
//
// Central styling foundation for the "editorial reading app" visual language.
// This file is STYLING ONLY — it defines tokens, the type ramp, spacing,
// elevation, and reusable view modifiers. No logic, state, or behavior lives
// here. Screens route their colors/fonts through these helpers so the look is
// consistent and a future palette/type change happens in one place.
//
// North star: a quiet, intimate, literary, late-night feel. The signature
// move is an editorial SERIF for human/emotional content (post bodies, reply
// bodies, screen titles, emotional headlines) and system SANS for all UI
// chrome (handles, timestamps, labels, buttons, counts, chips).
//
// Serif = Newsreader (bundled in Fonts/, registered via Info.plist UIAppFonts).
// Three static instances are shipped: Regular (400), Medium (500), Italic (400).
// Sans = SF Pro / system.

// MARK: - Type Ramp
//
// The locked ramp from the design spec. Sizes/weights are baked in; callers
// that need a one-off serif/sans size use the `serif*` / system helpers.
// Letter-spacing and line-height are NOT part of Font — apply them at the
// Text level via the `.toska*` text-style modifiers below (which carry the
// correct tracking + lineSpacing for each ramp entry).

enum ToskaFont {
    // Serif family — reference by PostScript name so the exact static instance
    // is selected (variable-font weight selection via Font.custom is flaky on
    // iOS; static instances are predictable).
    static func serif(_ size: CGFloat) -> Font       { .custom("Newsreader-Regular", size: size) }
    static func serifMedium(_ size: CGFloat) -> Font { .custom("Newsreader-Medium",  size: size) }
    static func serifItalic(_ size: CGFloat) -> Font { .custom("Newsreader-Italic",  size: size) }

    // Serif — content only (the locked ramp)
    static var screenTitle: Font    { serifMedium(24) }   // 24 / 500, tracking -0.5, lowercase
    static var greeting: Font       { serifItalic(18) }   // italic 18 / 400
    static var postBody: Font       { serif(14) }         // 14 / 400 — small & clean
    static var postDetailBody: Font { serif(22) }         // 22 / 400, line-height 1.45
    static var replyBody: Font      { serif(15.5) }       // 15.5 / 400, line-height 1.5

    // Sans — all UI chrome
    static var eyebrow: Font     { .system(size: 10.5, weight: .semibold) } // UPPERCASE, tracking 1.4
    static var handle: Font      { .system(size: 13,   weight: .semibold) }
    static var meta: Font        { .system(size: 12.5, weight: .regular) }
    static var actionCount: Font { .system(size: 11.5, weight: .medium) }
    static var chip: Font        { .system(size: 12,   weight: .semibold) }
    static func button(_ size: CGFloat = 15) -> Font { .system(size: size, weight: .semibold) }
}

// MARK: - Color Tokens
//
// Theme-aware tokens. The canonical light/dark values live in `LateNightTheme`
// (so existing screens that already read LateNightTheme.X pick up the new
// palette automatically). `ToskaColor` is a thin, well-named alias layer over
// those tokens plus the few new ones the design system introduces.

enum ToskaColor {
    static var bg: Color       { LateNightTheme.background }
    static var bg2: Color      { LateNightTheme.bg2 }
    static var card: Color     { LateNightTheme.cardBackground }
    static var card2: Color    { LateNightTheme.card2 }
    static var input: Color    { LateNightTheme.inputBackground }
    static var text: Color     { LateNightTheme.primaryText }
    static var text2: Color    { LateNightTheme.secondaryText }
    static var text3: Color    { LateNightTheme.tertiaryText }
    static var handle: Color   { LateNightTheme.handleText }
    static var divider: Color  { LateNightTheme.divider }
    static var accent: Color   { LateNightTheme.accent }
    static var time: Color     { LateNightTheme.timeText }
    static var badge: Color    { LateNightTheme.badge }
    static var scrim: Color    { LateNightTheme.scrim }
}

// MARK: - Emotion Tag Tints
//
// Theme-independent tints (and SF Symbols) per emotion. These intentionally
// stay constant across light/dark so a "longing" post reads the same blue at
// any hour. Mirrors the values in `sharedTags` / `tagColor(for:)` in FeedView.

enum ToskaEmotion {
    static func color(_ tag: String) -> Color { tagColor(for: tag) }
    static func icon(_ tag: String) -> String {
        sharedTags.first(where: { $0.name == tag })?.icon ?? "tag"
    }
}

// MARK: - Spacing
//
// 8-based vertical rhythm; 16 page gutter everywhere.

enum ToskaSpacing {
    static let gutter: CGFloat = 16          // page side gutter
    static let handleToBody: CGFloat = 8     // within a post card
    static let bodyToChip: CGFloat = 12
    static let chipToActions: CGFloat = 14
    static let cardCorner: CGFloat = 18
    static let cardMargin: CGFloat = 16
    static let cardGap: CGFloat = 10         // vertical gap between cards
    static let scrollBottomInset: CGFloat = 104 // clearance for the floating tab bar
}

// MARK: - Text-Style Modifiers
//
// Carry the ramp's tracking + line-height so call sites stay one-liners.
// Color is intentionally NOT baked in (call sites set foregroundColor) except
// where the ramp locks it (eyebrow = text-3).

extension View {
    /// Screen title — serif 26 / 500, tracking -0.5, lowercase, text color.
    func toskaScreenTitle() -> some View {
        self.font(ToskaFont.screenTitle)
            .tracking(-0.5)
            .foregroundColor(ToskaColor.text)
    }

    /// Eyebrow label — sans 10.5 / 600, tracking 1.4, UPPERCASE, text-3.
    func toskaEyebrow() -> some View {
        self.font(ToskaFont.eyebrow)
            .tracking(1.4)
            .foregroundColor(ToskaColor.text3)
    }

    /// Post body — serif 16 / 400, line-height 1.5 (lineSpacing 8).
    func toskaPostBody() -> some View {
        self.font(ToskaFont.postBody).lineSpacing(4)
    }

    /// Post detail body — serif 22 / 400, line-height 1.45 (lineSpacing ~10).
    func toskaPostDetailBody() -> some View {
        self.font(ToskaFont.postDetailBody).lineSpacing(10)
    }

    /// Reply body — serif 15.5 / 400, line-height 1.5 (lineSpacing ~7.75).
    func toskaReplyBody() -> some View {
        self.font(ToskaFont.replyBody).lineSpacing(7.75)
    }
}

// MARK: - Elevation
//
// SwiftUI's .shadow has no spread, so the spec's CSS `-Npx` spread terms are
// approximated with a tight low-opacity contact shadow stacked under a softer
// ambient one. Card = crisp hairline lift; floating bar = a touch more.

struct ToskaCardShadow: ViewModifier {
    func body(content: Content) -> some View {
        if LateNightTheme.isLateNight {
            content
                .shadow(color: Color.black.opacity(0.35), radius: 1, x: 0, y: 1)
                .shadow(color: Color.black.opacity(0.6),  radius: 9, x: 0, y: 8)
        } else {
            content
                .shadow(color: Color(hex: "14130F").opacity(0.035), radius: 1.2, x: 0, y: 1)
                .shadow(color: Color(hex: "14130F").opacity(0.16),  radius: 8,   x: 0, y: 7)
        }
    }
}

struct ToskaFloatingShadow: ViewModifier {
    func body(content: Content) -> some View {
        if LateNightTheme.isLateNight {
            content
                .shadow(color: Color.black.opacity(0.4),  radius: 3,  x: 0, y: 2)
                .shadow(color: Color.black.opacity(0.55), radius: 18, x: 0, y: 16)
        } else {
            content
                .shadow(color: Color(hex: "14130F").opacity(0.06), radius: 3,  x: 0, y: 2)
                .shadow(color: Color(hex: "14130F").opacity(0.28), radius: 18, x: 0, y: 16)
        }
    }
}

extension View {
    func toskaCardShadow() -> some View { modifier(ToskaCardShadow()) }
    func toskaFloatingShadow() -> some View { modifier(ToskaFloatingShadow()) }

    /// Post-card container: card bg, radius 18, 1px hairline divider border,
    /// + card shadow. The crisp border + subtle lift is the spec's "not a soft
    /// float" look.
    func toskaCard(cornerRadius: CGFloat = ToskaSpacing.cardCorner) -> some View {
        self
            .background(ToskaColor.card)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(ToskaColor.divider, lineWidth: 1)
            )
            .toskaCardShadow()
    }
}

// MARK: - Paper Grain
//
// Subtle fractal-noise overlay over the whole surface (3% light / 5% dark),
// non-interactive. The noise image is generated once via Core Image and cached,
// then tiled — cheap to composite and stable across renders (a per-frame
// random source would shimmer). Apply at a screen/root background level with
// `.overlay(ToskaPaperGrain())`.

struct ToskaPaperGrain: View {
    var body: some View {
        Group {
            if let img = ToskaPaperGrain.noise {
                Image(uiImage: img)
                    .resizable(resizingMode: .tile)
                    .opacity(LateNightTheme.isLateNight ? 0.05 : 0.03)
            } else {
                Color.clear
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    /// 160×160 monochrome noise tile, generated once.
    static let noise: UIImage? = {
        let ctx = CIContext(options: nil)
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return nil }
        // Desaturate to grayscale so the grain doesn't tint the surface.
        let mono = noise.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0.0,
            kCIInputBrightnessKey: 0.0,
            kCIInputContrastKey: 1.0,
        ])
        let rect = CGRect(x: 0, y: 0, width: 160, height: 160)
        guard let cg = ctx.createCGImage(mono, from: rect) else { return nil }
        return UIImage(cgImage: cg)
    }()
}
