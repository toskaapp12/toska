import SwiftUI
import UIKit
import Photos
import FirebaseAuth
import FirebaseFirestore

// Replies carry no denormalized isShareable (posts do, stamped at create and
// kept current by the onAllowSharingChanged backfill), so reply-share consent
// is resolved at TAP time from the author's public allowSharing projection on
// their user doc. Fail CLOSED: a failed read must never publish someone's
// words. Missing field mirrors the post-side default (isShareable ?? true).
enum ShareConsent {
    /// The public share-page link for a post, or nil when no such page exists.
    /// Mirrors the server's render gate in functions/sharePage.js exactly —
    /// live + isShareable, never letters/whispers/midnight (ephemeral or
    /// private kinds 404 on the web). Handing out a link the page would 404
    /// is worse than handing out no link, so this is the ONE place the rule
    /// lives client-side; every call site passes through here.
    static func publicShareURL(postId: String, isShareable: Bool,
                               isLetter: Bool, isWhisper: Bool,
                               isMidnight: Bool) -> URL? {
        guard isShareable, !isLetter, !isWhisper, !isMidnight,
              !postId.isEmpty else { return nil }
        // Reply-repost rows carry {reposterUid}_replyrepost_{replyId}: there is
        // no /p/ POST target for a reposted reply (the reply isn't a standalone
        // shareable post), and the id embeds the reposter's uid. The "_repost_"
        // strip below does NOT match "_replyrepost_" (the char before "repost" is
        // "y"), so without this guard the raw uid-bearing id rode the public URL —
        // the same anonymity leak the "_repost_" strip closes for post-reposts.
        // Suppress the public link entirely, exactly as replies do.
        if postId.contains("_replyrepost_") { return nil }
        // Repost rows carry the composite doc id ({reposterUid}_repost_{originalId}).
        // The server 301s it to the original anyway, but the composite id embeds
        // the reposter's uid — identity never rides a public URL, so link straight
        // to the original (same as the web app's copy-link). uids and auto-ids are
        // alphanumeric, so the first "_repost_" is always the separator.
        let shareId = postId.range(of: "_repost_").map { String(postId[$0.upperBound...]) } ?? postId
        guard !shareId.isEmpty else { return nil }
        return URL(string: "https://app.toskaapp.com/p/\(shareId)")
    }

    static func authorAllowsSharing(_ authorId: String) async -> Bool {
        guard !authorId.isEmpty else { return false }
        do {
            let snap = try await Firestore.firestore()
                .collection("users").document(authorId).getDocumentAsync()
            guard let data = snap.data() else { return false }
            return data["allowSharing"] as? Bool ?? true
        } catch {
            return false
        }
    }
}

@MainActor
struct ShareCardView: View {
    let text: String
    let handle: String
    let feltCount: Int
    let tag: String?
    // Public share-page link (ShareConsent.publicShareURL). nil for replies
    // and for kinds the web page won't serve (letters/whispers/midnight) —
    // when nil the card shares image-only, exactly the pre-link behavior.
    var shareURL: URL? = nil

    @Environment(\.dismiss) var dismiss
    // Default to "dawn" (index 8) — the first LIGHT mood. Indices 0–7 are dark
    // moods, 8–12 are light (dawn, paper, blush, sage, frost); the share card
    // opens on the light editorial look by default.
    @State private var selectedStyle = 8
    @State private var selectedFont = 0
    @State private var selectedSize = 1
    // Secondary controls (card shape + felt-count) start collapsed so the sheet
    // is uncluttered by default; tap "more options" to reveal them.
    @State private var showOptions = false
    // Gentle card entrance (scale + fade) when the sheet opens.
    @State private var cardAppeared = false
    @State private var selectedAlignment = 1
    @State private var selectedRatio = 0
    // User-toggleable: show or hide the "X felt this" line on the share card.
    // Defaults to true (matches previous always-on-when-> 0 behavior), but
    // users sharing a post they want to feel less performative can hide it.
    @State private var showFeltCount = true
    // "custom" mood (2026-07-31 owner): a user-picked flat background color.
    // selectedStyle == customStyle activates it; ink/accents adapt to the
    // color's brightness (customColorIsDark) so any pick stays legible.
    @State private var customColor: Color = Color(hex: "35284f")
    @State private var showSharedConfirmation = false
    @State private var savedToPhotos = false
    @State private var showSaveError = false
    // Gates the share-button row while ImageRenderer does its work. The
    // renderer is @MainActor, so it blocks the UI for ~200-500ms on a full-
    // size card rasterize — without this flag, the user tapping a button saw
    // a frozen app until the share sheet finally appeared. We can't move the
    // render off main (the SwiftUI renderer requires main-actor context), so
    // the fix is purely perceived-latency: set the flag, yield one frame so
    // SwiftUI paints the disabled state, then render.
    @State private var isRendering = false
    // First-time sharing explainer (same once-only pattern as the compose
    // whisper/midnight/letter hints).
    @AppStorage("toska_hint_sharing") private var sharingHintSeen = false
    @State private var showSharingHint = false

    // Remember the last look (2026-07-31 owner): the composer reopens with
    // whatever style/font/size/alignment/ratio/color the user last actually
    // SHARED or SAVED with (persistCardLook) — repeat sharers keep a
    // recognizable look instead of resetting to dawn/serif every time.
    // Values are clamped on load so a stale/garbage default can't select a
    // control that no longer exists (e.g. the removed "wide" ratio).
    init(text: String, handle: String, feltCount: Int, tag: String?,
         shareURL: URL? = nil) {
        self.text = text
        self.handle = handle
        self.feltCount = feltCount
        self.tag = tag
        self.shareURL = shareURL
        let d = UserDefaults.standard
        func load(_ key: String, _ fallback: Int, max: Int) -> Int {
            guard let v = d.object(forKey: key) as? Int, (0...max).contains(v)
            else { return fallback }
            return v
        }
        _selectedStyle = State(initialValue: load("toska_card_last_style", 8, max: Self.customStyle))
        _selectedFont = State(initialValue: load("toska_card_last_font", 0, max: 3))
        _selectedSize = State(initialValue: load("toska_card_last_size", 1, max: 2))
        _selectedAlignment = State(initialValue: load("toska_card_last_align", 1, max: 2))
        _selectedRatio = State(initialValue: load("toska_card_last_ratio", 0, max: 1))
        if let hex = d.string(forKey: "toska_card_last_custom_hex"), hex.count == 6 {
            _customColor = State(initialValue: Color(hex: hex))
        }
    }

    /// Persist the current look — called from save/share/sticker, i.e. when
    /// a look is actually USED, not merely browsed.
    private func persistCardLook() {
        let d = UserDefaults.standard
        d.set(selectedStyle, forKey: "toska_card_last_style")
        d.set(selectedFont, forKey: "toska_card_last_font")
        d.set(selectedSize, forKey: "toska_card_last_size")
        d.set(selectedAlignment, forKey: "toska_card_last_align")
        d.set(selectedRatio, forKey: "toska_card_last_ratio")
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(customColor).getRed(&r, green: &g, blue: &b, alpha: &a)
        // Clamp before formatting: the iOS wheel can hand back wide-gamut
        // (P3) colors whose sRGB components land outside 0...1, and "%02x"
        // of a component beyond 255 emits three digits — the stored string
        // then fails the 6-char check on load and the color silently resets.
        func c(_ v: CGFloat) -> Int { Int(round(min(max(v, 0), 1) * 255)) }
        d.set(String(format: "%02x%02x%02x", c(r), c(g), c(b)),
              forKey: "toska_card_last_custom_hex")
    }

    // "dusk" (index 1) is the signature plum mood — placed near the front so it
    // reads prominently in the swatch row. Inserting it shifted every later mood
    // up by one, so the dark/light boundary is now an explicit set (see isDark)
    // rather than the old `< 7` cutoff.
    let styles = ["2am", "dusk", "numb", "bruise", "ashes", "unsent", "alone", "hollow", "dawn", "paper", "blush", "sage", "frost"]

    // Order the swatch picker shows: lighter, warmer moods FIRST (dawn, paper,
    // blush, sage, frost), then the darker night moods. Only the display order
    // changes — every index→style mapping (backgroundFor / styleHighlightColor /
    // isDark / brandTextColor …) is keyed to the original index and untouched.
    let styleDisplayOrder = [8, 9, 10, 11, 12, 0, 1, 2, 3, 4, 5, 6, 7]
    let fonts = ["serif", "sans", "typewriter", "hand"]
    // Two social-native shapes only (2026-07-31 owner): story (9:16 — IG/
    // TikTok stories) and square (1:1 — feed posts). The old landscape
    // "wide" fit no social surface and carried its own layout special-cases.
    let ratios = ["story", "square"]

    /// Sentinel style index for the user-picked custom color (one past the
    /// last named mood).
    static let customStyle = 13

    // MARK: - Fragment Sharing
    // A 500-char post shrinks to ~9pt to fit the card — nobody shares that.
    // The user can instead pick the line(s) that matter ("share just a
    // line"); the card, sticker, and copy-text all follow the selection.
    // Skipped sentences between selected ones become an ellipsis, the
    // honest mark of an excerpt.

    @State private var selectedSentences: Set<Int> = []
    @State private var showFragmentPicker = false

    /// The post split into sentence-ish fragments (terminator-greedy, so
    /// "i miss you..." stays one piece). Newlines end a fragment too.
    /// Terminator set covers Arabic (؟) and CJK (。！？) punctuation so
    /// non-Latin posts get the line picker too.
    var sentences: [String] {
        guard let regex = try? NSRegularExpression(pattern: "[^.!?…؟。！？\\n]+[.!?…؟。！？]*") else { return [text] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Offer the picker only when there's something to choose between.
    var fragmentsAvailable: Bool { text.count > 120 && sentences.count > 1 }

    /// What the card actually renders: the full post, or the selected
    /// fragments joined in order with "…" marking skipped sentences.
    var cardText: String {
        let all = sentences
        let picked = selectedSentences.filter { $0 < all.count }.sorted()
        guard !picked.isEmpty, picked.count < all.count else { return text }
        var parts: [String] = []
        var prev: Int? = nil
        for i in picked {
            if let p = prev, i > p + 1 { parts.append("…") }
            parts.append(all[i])
            prev = i
        }
        return parts.joined(separator: " ")
    }

    /// Explicit dark-mood index set. Dark moods: 0...7 (2am, dusk, numb, bruise,
    /// ashes, unsent, alone, hollow); light moods: 8...12 (dawn, paper, blush,
    /// sage, frost). Replaces the brittle `selectedStyle < 7` cutoff so inserting
    /// a mood can't silently flip a card's color scheme. The custom mood is
    /// dark or light depending on the picked color's brightness.
    func isDark(_ index: Int) -> Bool {
        index == Self.customStyle ? customColorIsDark : index <= 7
    }

    /// Relative luminance of the custom color — decides whether the card
    /// dresses it with light ink (dark ground) or dark ink (light ground).
    var customColorIsDark: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(customColor).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (0.2126 * r + 0.7152 * g + 0.0722 * b) < 0.55
    }

    var cardSize: CGSize {
        switch selectedRatio {
        case 1: return CGSize(width: 390, height: 390)
        default: return CGSize(width: 390, height: 690)
        }
    }

    // Uniform scale that fits the full-size card into the preview box
    // (≤292 wide, ≤518 tall) WITHOUT clipping — the card lays out at cardSize
    // and is scaled down, so the text wraps exactly as it will when shared.
    var previewScale: CGFloat {
        min(min(cardSize.width * 0.75, 292) / cardSize.width,
            min(cardSize.height * 0.75, 518) / cardSize.height)
    }

    var body: some View {
        ZStack {
            // Sheet ground: a clean, soft warm-white surface (barely-lavender
            // off-white, not stark) so the card preview reads clearly. A FIXED
            // light color — not LateNightTheme.background, which flips dark at
            // night. The card's white hairline + layered shadow keep it
            // separated whether the mood is dark (pops on light) or light.
            Color(hex: "F4F2F6")
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .light))
                            .foregroundColor(Color(hex: "8a8790"))
                    }
                    .accessibilityLabel("Close")
                    Spacer()
                    Text("share this")
                        .font(.custom("Georgia-Italic", size: 13))
                        .foregroundColor(Color(hex: "1a1720"))
                    Spacer()
                    Image(systemName: "xmark")
                        .font(.system(size: 14))
                        .foregroundColor(.clear)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Rectangle().fill(Color.black.opacity(0.05)).frame(height: 0.5)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        cardPreview
                            // Scale the card DOWN to fit (don't frame-clip it — that
                            // cut words off both sides). Frame to the scaled size so
                            // layout stays tight around the visible card.
                            .scaleEffect(previewScale)
                            .frame(width: cardSize.width * previewScale, height: cardSize.height * previewScale)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                            // Soft, layered "float": a tight contact shadow + a wide
                            // ambient one + a faint mood-tinted glow — premium and airy
                            // instead of the old single heavy 0.55-black drop. The white
                            // rim edges dark moods; the faint black hairline defines
                            // light moods against the light sheet.
                            .overlay(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .stroke(.white.opacity(0.18), lineWidth: 1)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .stroke(.black.opacity(0.04), lineWidth: 0.5)
                            )
                            .shadow(color: .black.opacity(0.16), radius: 12, y: 6)
                            .shadow(color: .black.opacity(0.09), radius: 30, y: 16)
                            .shadow(color: cardGlowColor.opacity(0.18), radius: 46, y: 10)
                            // Gentle entrance: the card settles in with a soft
                            // scale + fade when the sheet opens.
                            .scaleEffect(cardAppeared ? 1 : 0.95)
                            .opacity(cardAppeared ? 1 : 0)
                            .onAppear {
                                withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) {
                                    cardAppeared = true
                                }
                                // One-time explainer (mirrors the compose-option
                                // hints): the first time anyone opens a share
                                // sheet, say exactly what leaves the app — the
                                // words only, never a handle — and that a few
                                // shared posts may be featured on toskaapp.com.
                                // Consent scope lives with the author's "allow
                                // sharing" setting; this is the reader-facing
                                // half of that transparency.
                                if !sharingHintSeen {
                                    // The seen-flag is set in the alert's "got it"
                                    // action, NOT here: onAppear fires mid-sheet-
                                    // entrance, and a dropped presentation would
                                    // otherwise burn the once-only transparency
                                    // notice without it ever being read.
                                    showSharingHint = true
                                }
                            }
                            .padding(.top, 18)

                        // MARK: - Mood Swatches
                        // Visual chips that render each mood's ACTUAL background
                        // via backgroundFor(_:) — the same helper the live card
                        // uses — so what you tap is exactly what renders. Far
                        // more legible than a row of 13 tiny text labels.
                        moodSwatchRow

                        // MARK: - Type toolbar
                        // The old three stacked rows (font / size / alignment)
                        // collapsed into ONE compact bar with thin dividers.
                        typeToolbar

                        // MARK: - Fragment picker
                        // Long posts shrink to fit — offer sharing just the
                        // line(s) that matter instead.
                        if fragmentsAvailable {
                            fragmentSection
                        }

                        // MARK: - Ratio + felt-count (behind "more options")
                        VStack(spacing: 12) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) { showOptions.toggle() }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(showOptions ? "fewer options" : "more options")
                                        .font(ToskaFont.sans(11, weight: .medium))
                                    Image(systemName: showOptions ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 8, weight: .semibold))
                                }
                                .foregroundColor(Color(hex: "8a8790"))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(showOptions ? "Hide shape and felt-count options" : "Show shape and felt-count options")

                            if showOptions {
                                HStack(spacing: 10) {
                                    ratioControl

                                    if feltCount > 0 {
                                        Spacer(minLength: 8)
                                        feltCountPill
                                    } else {
                                        Spacer(minLength: 0)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 20)

                        // Small trailing breather only — the save/share bar lives in a
                        // bottom safeAreaInset now, which already reserves its own
                        // clearance; the old 30pt spacer double-padded the scroll end.
                        Color.clear.frame(height: 8)
                    }
                }
                // MARK: - Share Buttons
                // Solid, vibrant, recognizable destination buttons — the
                // whole point of this screen is getting cards OUT into the
                // world, so the share row is the loudest thing here.
                // Just two destinations: Save to Photos, or Share via the
                // iOS system sheet — which already lists whatever the user
                // has installed (Instagram, TikTok, X, Messages, …). No
                // app-specific buttons or Facebook App ID; we hand the
                // image to the OS and let the user pick.
                // These live OUTSIDE the scroll content: the card preview +
                // controls run past the fold on most screens, so pills placed
                // inside the ScrollView sit below the screen edge and get
                // clipped. Anchoring them as a safe-area inset keeps the
                // primary actions fully visible at every scroll position.
                .safeAreaInset(edge: .bottom) {
                    HStack(spacing: 12) {
                        sharePill(name: "save", icon: "arrow.down.to.line",
                                  colors: [Color.toskaAccentGold, Color(hex: "b8893f")]) {
                            saveToPhotos()
                        }
                        .accessibilityLabel("Save to Photos")
                        sharePill(name: "share", icon: "square.and.arrow.up",
                                  colors: [Color.toskaMidnightPurple, Color(hex: "6E5FB0")]) {
                            shareImage()
                        }
                        .accessibilityLabel("Share")
                    }
                    .disabled(isRendering)
                    .opacity(isRendering ? 0.5 : 1)
                    .overlay(alignment: .center) {
                        if isRendering {
                            ProgressView().tint(Color(hex: "1a1720").opacity(0.6))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    // Opaque bar ground (same fixed sheet surface) extended under
                    // the home indicator so scrolled content can't show through
                    // beneath the pills; hairline mirrors the header divider.
                    .background(Color(hex: "F4F2F6").ignoresSafeArea(edges: .bottom))
                    .overlay(alignment: .top) {
                        Rectangle().fill(Color.black.opacity(0.05)).frame(height: 0.5)
                    }
                }
            }

            if showSharedConfirmation {
                Color.black.opacity(0.7).ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.3)) {
                            showSharedConfirmation = false
                        }
                    }

                VStack(spacing: 14) {
                    Text(savedToPhotos
                         ? "saved to your photos"
                         : "someone's going to feel less alone\nbecause of what you just shared")
                        .font(.custom("Georgia-Italic", size: 15))
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)

                    Text(savedToPhotos
                         ? "share it whenever you're ready"
                         : "the things we can't say out loud\ntravel the farthest")
                        .font(ToskaFont.sans(11))
                        .foregroundColor(.white.opacity(0.2))
                        .multilineTextAlignment(.center)

                    Button {
                        withAnimation(.easeOut(duration: 0.3)) {
                            showSharedConfirmation = false
                            savedToPhotos = false
                        }
                    } label: {
                        Text("okay")
                            .font(ToskaFont.sans(12, weight: .medium))
                            .foregroundColor(.white.opacity(0.4))
                            .padding(.horizontal, 32)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(4)
                    }
                    .padding(.top, 6)
                }
                .padding(28)
                .background(Color(hex: "0e0e10"))
                .cornerRadius(4)
                .padding(.horizontal, 40)
                .transition(.opacity)
            }
        }
        .preferredColorScheme(.light)
        .alert("couldn't save", isPresented: $showSaveError) {
            Button("ok", role: .cancel) {}
        } message: {
            Text("toska needs permission to add to your photos. you can enable it in Settings › Privacy › Photos.")
        }
        .alert("sharing, quietly", isPresented: $showSharingHint) {
            Button("got it", role: .cancel) { sharingHintSeen = true }
        } message: {
            Text("this card carries the words only — no name, no handle, nothing that points back to the writer. sharing also includes a link to the post's page on toskaapp.com, anonymous in the same way. a few shared posts may also be featured there. writers can turn sharing off any time in settings.")
        }
    }

    // MARK: - Composer Controls

    /// App accent used for selected-state rings/ticks/fills across the composer.
    /// The brand plum reads cleanly on the light sheet (the old gold washed out
    /// against the warm-white surface).
    private var composerAccent: Color { Color.toskaMidnightPurple }

    /// Horizontal scroll of mood swatches. Each chip renders that mood's real
    /// backdrop (backgroundFor) with a small highlight-color dot; the selected
    /// chip gets a 2px accent ring + a slight scale-up.
    private var moodSwatchRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 13) {
                ForEach(styleDisplayOrder, id: \.self) { index in
                    let isSelected = selectedStyle == index
                    Button {
                        HapticManager.play(.tabSwitch)   // soft tactile tick on mood change
                        withAnimation(.easeInOut(duration: 0.3)) {
                            selectedStyle = index
                        }
                    } label: {
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.clear)
                                .frame(width: 54, height: 54)
                                .background(
                                    backgroundFor(index)
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                )
                                .overlay(alignment: .bottomTrailing) {
                                    Circle()
                                        .fill(styleHighlightColor(index))
                                        .frame(width: 6, height: 6)
                                        .padding(6)
                                        .opacity(0.85)
                                }
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(Color.black.opacity(0.10), lineWidth: 0.5)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(isSelected ? composerAccent : Color.clear, lineWidth: 2)
                                        .padding(-3)
                                )
                                .scaleEffect(isSelected ? 1.08 : 1.0)

                            Text(styles[index])
                                .font(ToskaFont.sans(11, weight: isSelected ? .semibold : .regular))
                                .foregroundColor(isSelected ? Color(hex: "1a1720") : Color(hex: "8a8790"))
                        }
                    }
                    .accessibilityLabel(styles[index])
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }

                customSwatch
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 4)
        }
    }

    /// The "custom" chip at the end of the mood row: the current color as
    /// the chip ground with the REAL system color well, visible at its
    /// natural size, centered on it — tapping the well opens the iOS color
    /// wheel (the previous invisible stretched-picker overlay never received
    /// taps on device). Tapping the chip around the well re-selects the
    /// custom mood with the current color; picking a color selects it too.
    private var customSwatch: some View {
        let isSelected = selectedStyle == Self.customStyle
        return VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(customColor)
                    .frame(width: 54, height: 54)
                    .onTapGesture {
                        HapticManager.play(.tabSwitch)
                        withAnimation(.easeInOut(duration: 0.3)) {
                            selectedStyle = Self.customStyle
                        }
                    }
                ColorPicker("", selection: $customColor, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 38, height: 38)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.black.opacity(0.10), lineWidth: 0.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? composerAccent : Color.clear, lineWidth: 2)
                    .padding(-3)
            )
            .scaleEffect(isSelected ? 1.08 : 1.0)
            .onChange(of: customColor) { _, _ in
                withAnimation(.easeInOut(duration: 0.3)) {
                    selectedStyle = Self.customStyle
                }
            }

            Text("custom")
                .font(ToskaFont.sans(11, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? Color(hex: "1a1720") : Color(hex: "8a8790"))
        }
        .accessibilityLabel("Custom color")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// One compact toolbar: font cycle | size segments | alignment segments.
    private var typeToolbar: some View {
        HStack(spacing: 0) {
            // Font cycle — tapping advances serif → sans → mono → hand.
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    selectedFont = (selectedFont + 1) % fonts.count
                }
            } label: {
                HStack(spacing: 6) {
                    Text("Aa")
                        .font(fontPickerFont(selectedFont))
                    Text(fonts[selectedFont])
                        .font(ToskaFont.sans(11, weight: .medium))
                        .foregroundColor(Color(hex: "8a8790"))
                }
                .foregroundColor(Color(hex: "1a1720"))
                .frame(maxWidth: .infinity)
                .frame(height: 30)
            }
            .accessibilityLabel("Font: \(fonts[selectedFont]). Tap to change.")

            toolbarDivider

            // Size — three steps.
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    let sizes: [CGFloat] = [10, 12, 15]
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { selectedSize = index }
                    } label: {
                        Text("A")
                            .font(.system(size: sizes[index], weight: selectedSize == index ? .bold : .regular))
                            .foregroundColor(selectedSize == index ? composerAccent : Color(hex: "8a8790"))
                            .frame(width: 26, height: 30)
                            .background(selectedSize == index ? composerAccent.opacity(0.14) : Color.clear)
                            .cornerRadius(5)
                    }
                    .accessibilityLabel(["Small text", "Medium text", "Large text"][index])
                    .accessibilityAddTraits(selectedSize == index ? .isSelected : [])
                }
            }
            .frame(maxWidth: .infinity)

            toolbarDivider

            // Alignment — three icons.
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    let icons = ["text.alignleft", "text.aligncenter", "text.alignright"]
                    let labels = ["Align left", "Align center", "Align right"]
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { selectedAlignment = index }
                    } label: {
                        Image(systemName: icons[index])
                            .font(.system(size: 11, weight: .light))
                            .foregroundColor(selectedAlignment == index ? composerAccent : Color(hex: "8a8790"))
                            .frame(width: 26, height: 30)
                            .background(selectedAlignment == index ? composerAccent.opacity(0.14) : Color.clear)
                            .cornerRadius(5)
                    }
                    .accessibilityLabel(labels[index])
                    .accessibilityAddTraits(selectedAlignment == index ? .isSelected : [])
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        // Lighter, airier than the old grey block — a barely-there wash + hairline
        // so it recedes and the card stays the focus.
        .background(Color.black.opacity(0.025))
        .cornerRadius(13)
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .stroke(Color.black.opacity(0.05), lineWidth: 0.5)
        )
        .padding(.horizontal, 20)
    }

    private var toolbarDivider: some View {
        Rectangle().fill(Color.black.opacity(0.06)).frame(width: 0.5, height: 18)
    }

    /// "share just a line" — collapsed by default; expands into tappable
    /// sentence rows. Selecting a subset re-renders the card with only those
    /// lines (see cardText); clearing returns to the full post.
    private var fragmentSection: some View {
        VStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showFragmentPicker.toggle() }
            } label: {
                // "Fragment active" means cardText actually differs from the
                // full post — selecting EVERY sentence falls back to the full
                // post (cardText), so the label must not claim a fragment then.
                let effectiveCount = selectedSentences.filter { $0 < sentences.count }.count
                let fragmentActive = effectiveCount > 0 && effectiveCount < sentences.count
                HStack(spacing: 4) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 9, weight: .semibold))
                    Text(fragmentActive
                         ? "sharing \(effectiveCount) of \(sentences.count) lines"
                         : "share just a line")
                        .font(ToskaFont.sans(11, weight: .medium))
                    Image(systemName: showFragmentPicker ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundColor(fragmentActive ? composerAccent : Color(hex: "8a8790"))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showFragmentPicker ? "Hide line picker" : "Share just a line")

            if showFragmentPicker {
                VStack(spacing: 6) {
                    ForEach(Array(sentences.enumerated()), id: \.offset) { index, sentence in
                        let isOn = selectedSentences.contains(index)
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                if isOn { selectedSentences.remove(index) }
                                else { selectedSentences.insert(index) }
                            }
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 13))
                                    .foregroundColor(isOn ? composerAccent : Color(hex: "c9c6cf"))
                                    .padding(.top, 1)
                                Text(sentence)
                                    .font(ToskaFont.sans(12))
                                    .foregroundColor(isOn ? Color(hex: "1a1720") : Color(hex: "8a8790"))
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(isOn ? composerAccent.opacity(0.08) : Color.black.opacity(0.02))
                            .cornerRadius(9)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isOn ? .isSelected : [])
                    }

                    if !selectedSentences.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { selectedSentences = [] }
                        } label: {
                            Text("share the whole post")
                                .font(ToskaFont.sans(11, weight: .medium))
                                .foregroundColor(Color(hex: "8a8790"))
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
    }

    /// Clean segmented control for the card ratio.
    private var ratioControl: some View {
        HStack(spacing: 2) {
            ForEach(0..<ratios.count, id: \.self) { index in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { selectedRatio = index }
                } label: {
                    Text(ratios[index])
                        .font(ToskaFont.sans(11, weight: selectedRatio == index ? .semibold : .regular))
                        .foregroundColor(selectedRatio == index ? composerAccent : Color(hex: "8a8790"))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(selectedRatio == index ? composerAccent.opacity(0.14) : Color.clear)
                        .cornerRadius(7)
                }
                .accessibilityAddTraits(selectedRatio == index ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.black.opacity(0.04))
        .cornerRadius(9)
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.black.opacity(0.10), lineWidth: 0.5)
        )
    }

    /// Single compact pill toggling the "X felt this" line.
    private var feltCountPill: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { showFeltCount.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: showFeltCount ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11))
                    .foregroundColor(showFeltCount ? composerAccent : Color(hex: "8a8790"))
                Text("felt count")
                    .font(ToskaFont.sans(11, weight: showFeltCount ? .medium : .regular))
                    .foregroundColor(showFeltCount ? Color(hex: "1a1720") : Color(hex: "8a8790"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.black.opacity(0.04))
            .cornerRadius(9)
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(Color.black.opacity(0.10), lineWidth: 0.5)
            )
        }
        .accessibilityLabel(showFeltCount ? "Hide felt count" : "Show felt count")
    }

    // MARK: - Font Helpers

    /// The "Aa" chip previews the ACTUAL face each slot draws with.
    func fontPickerFont(_ index: Int) -> Font {
        switch index {
        case 0: return .custom("Newsreader-Medium", size: 10)
        case 1: return .custom("HankenGrotesk-Regular", size: 10)
        case 2: return .custom("AmericanTypewriter", size: 10)
        case 3: return .custom("Newsreader-Italic", size: 10)
        default: return .system(size: 10)
        }
    }

    // Font lineup (2026-07-31, owner-approved from the font-options pitch):
    // serif/hand = the brand Newsreader faces posts are already read in
    // (Medium cut per the postBody faint-Regular decision); sans = Hanken
    // Grotesk, the app's own chrome face; "typewriter" = American Typewriter
    // (built into iOS) — an app of unsent letters shouldn't quote them in a
    // terminal font, and the slot was renamed to match.
    func quoteFont(size: CGFloat) -> Font {
        switch selectedFont {
        case 0: return .custom("Newsreader-Medium", size: size)
        case 1: return .custom("HankenGrotesk-Regular", size: size)
        case 2: return .custom("AmericanTypewriter", size: size)
        case 3: return .custom("Newsreader-Italic", size: size)
        default: return .custom("Newsreader-Medium", size: size)
        }
    }

    // Labeled pill destination (Save / Share) — replaces the round icon buttons
    // with a cleaner, more tappable capsule that reads as a clear call-to-action.
    func sharePill(name: String, icon: String, colors: [Color], action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                Text(name)
                    .font(ToskaFont.sans(15, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(
                Capsule().fill(
                    LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            )
            .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 0.75))
            .shadow(color: colors.first?.opacity(0.35) ?? .clear, radius: 9, y: 4)
        }
        .buttonStyle(SharePressStyle())
    }

    // MARK: - Style Helpers

    func styleHighlightColor(_ index: Int) -> Color {
        switch index {
        case 0: return Color.toskaBlue              // 2am
        case 1: return Color.toskaMidnightPurple    // dusk (signature plum)
        case 2: return Color(hex: "808080")         // numb
        case 3: return Color.toskaMidnightPurple    // bruise
        case 4: return Color.toskaErrorRed          // ashes
        case 5: return Color.toskaUnsentBlue        // unsent
        case 6: return Color.toskaAccentTan         // alone
        case 7: return Color(hex: "5a6a5a")         // hollow
        case 8: return Color.toskaAccentGold        // dawn
        case 9: return Color.toskaMidGray           // paper
        case 10: return Color.toskaWhisperPink      // blush
        case 11: return Color.toskaFollowGreen      // sage
        case 12: return Color.toskaUnsentBlue       // frost
        // custom — neutral accent derived from the ground's brightness, so
        // tag/felt/rule/glow chrome stays quiet on any user-picked color.
        case Self.customStyle:
            return customColorIsDark ? Color(hex: "cfc4e8") : Color(hex: "4a4258")
        default: return Color.toskaBlue
        }
    }

    var cardGlowColor: Color {
        styleHighlightColor(selectedStyle)
    }

    // MARK: - Card Preview

    // The card's inner content (tag · quote mark · quote · attribution footer),
    // laid out in the fixed 390-wide card coordinate space. This is the SINGLE
    // source of truth used by BOTH the live preview and the exported image, so
    // they can never drift apart again (the old code duplicated this with
    // slightly different font/padding/lineSpacing, which is why text that fit the
    // preview clipped in the shared image).
    @ViewBuilder
    var cardBody: some View {
        VStack(spacing: 0) {
            // Vertically CENTERED (equal spacers) — quote dead-center, footer below.
            Spacer(minLength: 0).frame(maxHeight: .infinity)

            if let tag, !tag.isEmpty {
                HStack(spacing: 4) {
                    Circle()
                        .fill(accentColor.opacity(0.4))
                        .frame(width: 4, height: 4)
                    Text(tag)
                        .font(ToskaFont.sans(11, weight: .semibold))
                        .tracking(1)
                        .foregroundColor(accentColor.opacity(0.5))
                        // Single line: the layout reserves a fixed height for
                        // everything but the quote, so a wrapping tag would eat
                        // un-budgeted vertical space and could push the footer off.
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.bottom, 14)
            }

            Text(quoteMark)
                .font(.custom("Newsreader-Medium", size: 34))
                .foregroundColor(accentColor.opacity(isDarkStyle ? 0.18 : 0.14))
                .padding(.bottom, 2)

            Text(cardText)
                .font(quoteFont(size: fittedFontSize))
                .foregroundColor(textColor)
                .lineSpacing(lineSpacing)
                .multilineTextAlignment(textAlignment)
                // fittedFontSize already MEASURED that the text fits within
                // quoteMaxHeight (to 93%); the minimumScaleFactor is a final
                // belt-and-suspenders against any SwiftUI-vs-UIKit rounding so a
                // long message can NEVER clip — the whole point of this rewrite.
                // 2026-07-30 owner: the card must NEVER truncate — a 500-word
                // letter shrinks until it fits, period. 0.7 wasn't enough when
                // the UIKit measurement and SwiftUI layout disagreed at large
                // user-selected sizes; 0.15 makes overflow physically
                // impossible within the measured range.
                .minimumScaleFactor(0.15)
                .padding(.horizontal, textPadding)
                // FIXED height, not maxHeight (2026-07-30 matrix harness): in
                // floor-bound cases (text so long even 5pt doesn't fit — only
                // reachable beyond the 500-char post limit) Text's scale-factor
                // sizing reported MORE than the maxHeight cap, and the overflow
                // pushed the footer rule + wordmark off the card bottom. With a
                // fixed frame the footer's slot is arithmetic: quote mark +
                // this + footer ≤ card height, always; the text scales itself
                // into the frame via minimumScaleFactor. +3pt cushions
                // SwiftUI-vs-UIKit rounding; for all fitting text this equals
                // the old reported size (ideal height), so layout is unchanged.
                .frame(height: fittedQuoteHeight)

            Spacer(minLength: 0).frame(maxHeight: .infinity)

            VStack(spacing: 6) {
                if feltCount > 0 && showFeltCount {
                    Text("\(formatCount(feltCount)) felt this")
                        .font(ToskaFont.sans(11, weight: .medium))
                        .foregroundColor(accentColor.opacity(0.35))
                }

                Rectangle()
                    .fill(accentColor.opacity(isDarkStyle ? 0.1 : 0.08))
                    .frame(width: 24, height: 0.5)
                    .padding(.vertical, 3)

                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(accentColor.opacity(isDarkStyle ? 0.12 : 0.08))
                        .frame(width: 14, height: 14)
                        .overlay(
                            Text("t")
                                .font(.custom("Newsreader-Italic", size: 10))
                                .foregroundColor(isDarkStyle ? .white.opacity(0.5) : brandTextColor.opacity(0.4))
                        )
                    Text("toska")
                        .font(.custom("Newsreader-Italic", size: 12))
                        .foregroundColor(isDarkStyle ? .white.opacity(0.25) : brandTextColor.opacity(0.3))
                }

                // The image travels as pixels — reposts and screenshots strip
                // every link. This whisper of a domain is the only way back
                // to toska that survives re-sharing.
                Text("toskaapp.com")
                    .font(ToskaFont.sans(8, weight: .medium))
                    .tracking(0.6)
                    .foregroundColor(isDarkStyle ? .white.opacity(0.16) : brandTextColor.opacity(0.22))
            }
            .padding(.bottom, 20)
        }
    }

    /// cardDecorations constrained to the card's bounds. The raw decoration
    /// ellipses are LARGER than the card (glow bleeds past the edges by
    /// design); unconstrained they inflate the ZStack's union size past
    /// cardSize, and the card body then lays out against the UNION — on wide
    /// cards (260pt tall vs 320pt+ ellipse stacks, plus 400pt+ ellipses on
    /// square unsent/blush) that pushed the footer rule + wordmark below the
    /// visible card in both preview and export (found by the 2026-07-30
    /// matrix harness). Frame + clip pins the union to the card so the body
    /// always lays out in true card coordinates.
    var boundedCardDecorations: some View {
        cardDecorations
            .frame(width: cardSize.width, height: cardSize.height)
            .clipped()
    }

    /// One shared noise tile (mid-gray ±16), generated once per launch.
    /// Overlay-blended at low opacity it reads as paper grain, not static.
    private static let grainTile: UIImage = {
        let dim = 144
        guard let ctx = CGContext(
            data: nil, width: dim, height: dim, bitsPerComponent: 8,
            bytesPerRow: dim, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let data = ctx.data else { return UIImage() }
        let buf = data.bindMemory(to: UInt8.self, capacity: dim * dim)
        for i in 0..<(dim * dim) { buf[i] = UInt8.random(in: 112...144) }
        guard let cg = ctx.makeImage() else { return UIImage() }
        return UIImage(cgImage: cg)
    }()

    /// Subtle paper-grain wash over the mood ground — pushes the card from
    /// "flat gradient" toward "editorial object". Sits between decorations
    /// and text; never on the transparent sticker.
    var cardGrain: some View {
        Image(uiImage: Self.grainTile)
            .resizable(resizingMode: .tile)
            .frame(width: cardSize.width, height: cardSize.height)
            .blendMode(.overlay)
            .opacity(isDarkStyle ? 0.4 : 0.3)
            .allowsHitTesting(false)
    }

    var cardPreview: some View {
        ZStack {
            cardBackground
            boundedCardDecorations
            cardGrain
            cardBody
        }
        // Lay the preview out at the EXACT export size (the sheet then
        // scales it down visually). Without this the ZStack inherits the
        // ScrollView's proposal and the body could lay out at a different
        // height than the exported image — the preview and export must share
        // identical geometry, not just identical content.
        .frame(width: cardSize.width, height: cardSize.height)
        // The card is fixed-size artwork: its quote is auto-fitted by
        // fittedFontSize, which measures with FIXED UIFont sizes. But
        // Font.custom (Georgia/Georgia-Italic) and ToskaFont.sans scale with
        // Dynamic Type, while ImageRenderer runs in a default environment —
        // so without this pin, a non-default text size renders the preview
        // bigger than the measurement AND differently from the export.
        // Pinning .large keeps preview == measurement == export on every
        // device setting. (Sheet chrome outside the card keeps Dynamic Type.)
        .dynamicTypeSize(.large)
    }

    var quoteMark: String { "\u{201C}" }

    var isDarkStyle: Bool { isDark(selectedStyle) }

    var brandTextColor: Color {
        switch selectedStyle {
        case 8: return Color(hex: "4a4035")   // dawn
        case 9: return Color(hex: "333333")   // paper
        case 10: return Color(hex: "5a3040")  // blush
        case 11: return Color(hex: "2a4038")  // sage
        case 12: return Color(hex: "2a3548")  // frost
        default: return Color(hex: "333333")
        }
    }

    var sizeMultiplier: CGFloat {
        switch selectedSize {
        case 0: return 0.8
        case 2: return 1.25
        default: return 1.0
        }
    }

    // A post can be up to 500 chars. Cap the quote's height (leaving room for
    // the quote mark / tag above and the toska footer below) so a long message
    // scales DOWN to fit rather than overflowing the card. Combined with
    // minimumScaleFactor on the Text, this GUARANTEES even a 500-char post
    // always fits, in any ratio.
    var quoteMaxHeight: CGFloat {
        cardSize.height - 215
    }

    /// Largest font the card would ever use (short posts). The fit search below
    /// scales DOWN from here for longer text. Wide cards get a smaller ceiling
    /// (least vertical room). `sizeMultiplier` applies the user's size control.
    var maxFontSize: CGFloat { 24 * sizeMultiplier }

    /// The font size the quote is ACTUALLY drawn at — computed by MEASURING the
    /// text (UIKit boundingRect) and binary-searching the largest point size at
    /// which it fits within the quote box (width = card − 2·padding, height =
    /// quoteMaxHeight). This replaces the old coarse length-bucket heuristic +
    /// minimumScaleFactor, which could still CLIP a long message (the scale
    /// factor bottoms out for multiline height-fitting). The SAME value drives
    /// the live preview AND the exported image, so they're byte-for-byte WYSIWYG.
    var fittedFontSize: CGFloat {
        guard !cardText.isEmpty else { return maxFontSize }
        let maxW = cardSize.width - 2 * textPadding
        // Fit to 93% of the box: a small safety margin so any SwiftUI-vs-UIKit
        // sub-pixel layout difference can't tip a fitted size into a clip.
        let maxH = quoteMaxHeight * 0.93
        var lo: CGFloat = 5, hi = maxFontSize, best: CGFloat = 5
        // 14 iterations resolves to <0.01pt over the [8, 24] range.
        for _ in 0..<14 {
            let mid = (lo + hi) / 2
            if measuredQuoteHeight(fontSize: mid, width: maxW) <= maxH {
                best = mid; lo = mid
            } else {
                hi = mid
            }
        }
        return best
    }

    /// The quote frame's exact height: measured height at the fitted size
    /// (plus a rounding cushion), clamped to the budget. See the .frame note
    /// in cardBody for why this is a fixed height rather than a maxHeight.
    var fittedQuoteHeight: CGFloat {
        guard !cardText.isEmpty else { return quoteMaxHeight }
        let maxW = cardSize.width - 2 * textPadding
        return min(measuredQuoteHeight(fontSize: fittedFontSize, width: maxW) + 3,
                   quoteMaxHeight)
    }

    // MUST name the same faces quoteFont draws with — the fit engine
    // measures with these fonts, and a mismatch reopens the truncation gap.
    private func measuringUIFont(size: CGFloat) -> UIFont {
        switch selectedFont {
        case 1: return UIFont(name: "HankenGrotesk-Regular", size: size) ?? .systemFont(ofSize: size)
        case 2: return UIFont(name: "AmericanTypewriter", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        case 3: return UIFont(name: "Newsreader-Italic", size: size) ?? .italicSystemFont(ofSize: size)
        default: return UIFont(name: "Newsreader-Medium", size: size) ?? .systemFont(ofSize: size)
        }
    }

    private var nsAlignment: NSTextAlignment {
        switch selectedAlignment {
        case 0: return .left
        case 2: return .right
        default: return .center
        }
    }

    private func measuredQuoteHeight(fontSize: CGFloat, width: CGFloat) -> CGFloat {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = lineSpacing
        para.alignment = nsAlignment
        let rect = (cardText as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: measuringUIFont(size: fontSize), .paragraphStyle: para],
            context: nil
        )
        return ceil(rect.height)
    }

    var lineSpacing: CGFloat {
        let base: CGFloat = cardText.count > 200 ? 5 : 7
        return base * sizeMultiplier
    }

    var textPadding: CGFloat { 30 }

    var textAlignment: TextAlignment {
        switch selectedAlignment {
        case 0: return .leading
        case 2: return .trailing
        default: return .center
        }
    }

    // MARK: - Card Backgrounds

    /// Single source of truth for a mood's backdrop. BOTH the live preview card
    /// and the swatch chips call this so the swatch always matches the rendered
    /// card exactly. Indices map 1:1 to `styles`.
    @ViewBuilder
    func backgroundFor(_ index: Int) -> some View {
        switch index {
        case 0: Color(hex: "08080a")                                                                                                        // 2am
        case 1: LinearGradient(colors: [Color(hex: "1a1426"), Color(hex: "241a36"), Color(hex: "140e1e")], startPoint: .top, endPoint: .bottom) // dusk — signature plum
        case 2: Color(hex: "111111")                                                                                                        // numb
        case 3: LinearGradient(colors: [Color(hex: "0c0814"), Color(hex: "100a1e"), Color(hex: "08060e")], startPoint: .top, endPoint: .bottom) // bruise
        case 4: LinearGradient(colors: [Color(hex: "0e0a08"), Color(hex: "140e0c"), Color(hex: "0a0806")], startPoint: .top, endPoint: .bottom) // ashes
        case 5: LinearGradient(colors: [Color(hex: "080c14"), Color(hex: "0a1018"), Color(hex: "06080e")], startPoint: .topLeading, endPoint: .bottomTrailing) // unsent
        case 6: LinearGradient(colors: [Color(hex: "0e0c08"), Color(hex: "14100a"), Color(hex: "0a0806")], startPoint: .top, endPoint: .bottom) // alone
        case 7: Color(hex: "060606")                                                                                                        // hollow
        case 8: LinearGradient(colors: [Color(hex: "f5efe6"), Color(hex: "ece4d8"), Color(hex: "e8dfd0")], startPoint: .top, endPoint: .bottom) // dawn
        case 9: Color(hex: "f0f0ec")                                                                                                        // paper
        case 10: LinearGradient(colors: [Color(hex: "f5e8ec"), Color(hex: "f0dce2"), Color(hex: "ecdae0")], startPoint: .top, endPoint: .bottom) // blush
        case 11: LinearGradient(colors: [Color(hex: "e8f0ec"), Color(hex: "dce8e2"), Color(hex: "d4e0da")], startPoint: .top, endPoint: .bottom) // sage
        case 12: LinearGradient(colors: [Color(hex: "e8eef5"), Color(hex: "dce4f0"), Color(hex: "d4dcea")], startPoint: .top, endPoint: .bottom) // frost
        case Self.customStyle: customColor                                                                                                  // custom — user-picked flat
        default: Color(hex: "08080a")
        }
    }

    var cardBackground: some View {
        backgroundFor(selectedStyle)
    }

    // MARK: - Card Decorations

    var cardDecorations: some View {
        Group {
            switch selectedStyle {
            case 0: // 2am — cool blue pool low, faint top counter-glow for depth
                ZStack {
                    VStack {
                        Spacer()
                        Ellipse()
                            .fill(RadialGradient(colors: [Color.toskaBlue.opacity(0.14), Color.clear], center: .center, startRadius: 0, endRadius: 260))
                            .frame(width: 460, height: 300)
                            .offset(y: 70)
                    }
                    VStack {
                        Ellipse()
                            .fill(RadialGradient(colors: [Color.toskaBlue.opacity(0.06), Color.clear], center: .center, startRadius: 0, endRadius: 200))
                            .frame(width: 320, height: 240)
                            .offset(y: -50)
                        Spacer()
                    }
                }
            case 1: // dusk — signature plum; rich offset double-glow for atmosphere
                ZStack {
                    VStack {
                        Ellipse()
                            .fill(RadialGradient(colors: [Color.toskaMidnightPurple.opacity(0.18), Color.clear], center: .center, startRadius: 0, endRadius: 260))
                            .frame(width: 420, height: 320)
                            .offset(x: -40, y: -40)
                        Spacer()
                    }
                    VStack {
                        Spacer()
                        Ellipse()
                            .fill(RadialGradient(colors: [Color.toskaMidnightPurple.opacity(0.12), Color.clear], center: .center, startRadius: 0, endRadius: 240))
                            .frame(width: 400, height: 300)
                            .offset(x: 50, y: 60)
                    }
                }
            case 3: // bruise — purple bloom up top
                VStack {
                    Ellipse()
                        .fill(RadialGradient(colors: [Color.toskaMidnightPurple.opacity(0.14), Color.clear], center: .center, startRadius: 0, endRadius: 240))
                        .frame(width: 400, height: 300)
                        .offset(y: -40)
                    Spacer()
                }
            case 4: // ashes — warm ember low
                VStack {
                    Spacer()
                    Ellipse()
                        .fill(RadialGradient(colors: [Color.toskaErrorRed.opacity(0.12), Color.clear], center: .center, startRadius: 0, endRadius: 230))
                        .frame(width: 400, height: 280)
                        .offset(y: 50)
                }
            case 5: // unsent — centered steel-blue haze
                Ellipse()
                    .fill(RadialGradient(colors: [Color.toskaUnsentBlue.opacity(0.13), Color.clear], center: .center, startRadius: 0, endRadius: 240))
                    .frame(width: 420, height: 420)
            case 6: // alone — warm tan glow, slightly low-left
                VStack {
                    Ellipse()
                        .fill(RadialGradient(colors: [Color.toskaAccentTan.opacity(0.13), Color.clear], center: .center, startRadius: 0, endRadius: 200))
                        .frame(width: 340, height: 340)
                        .offset(x: -30, y: 40)
                    Spacer()
                }
            case 8: // dawn — golden sunrise from the top
                VStack {
                    Ellipse()
                        .fill(RadialGradient(colors: [Color.toskaAccentGold.opacity(0.20), Color.clear], center: .center, startRadius: 0, endRadius: 250))
                        .frame(width: 420, height: 320)
                        .offset(y: -30)
                    Spacer()
                }
            case 10: // blush — soft pink, full bleed
                Ellipse()
                    .fill(RadialGradient(colors: [Color.toskaWhisperPink.opacity(0.16), Color.clear], center: .center, startRadius: 0, endRadius: 230))
                    .frame(width: 400, height: 400)
            case 11: // sage — green pool low
                VStack {
                    Spacer()
                    Ellipse()
                        .fill(RadialGradient(colors: [Color.toskaFollowGreen.opacity(0.16), Color.clear], center: .center, startRadius: 0, endRadius: 240))
                        .frame(width: 420, height: 300)
                        .offset(y: 60)
                }
            case 12: // frost — cool blue from the top
                VStack {
                    Ellipse()
                        .fill(RadialGradient(colors: [Color.toskaUnsentBlue.opacity(0.16), Color.clear], center: .center, startRadius: 0, endRadius: 240))
                        .frame(width: 400, height: 320)
                        .offset(y: -30)
                    Spacer()
                }
            default: // numb (2), hollow (7), paper (9) — intentionally flat/quiet
                EmptyView()
            }
        }
    }

    // MARK: - Style Colors

    var textColor: Color {
        switch selectedStyle {
        case 0: return .white.opacity(0.75)              // 2am
        case 1: return Color(hex: "ded6f2").opacity(0.85) // dusk (warm lavender on plum)
        case 2: return .white.opacity(0.5)               // numb
        case 3: return Color(hex: "c8c0e0").opacity(0.8) // bruise
        case 4: return Color(hex: "d8c0b0").opacity(0.7) // ashes
        case 5: return Color(hex: "b0c8e0").opacity(0.75)// unsent
        case 6: return Color(hex: "e0d0b8").opacity(0.7) // alone
        case 7: return .white.opacity(0.35)              // hollow
        case 8: return Color(hex: "4a4035")              // dawn
        case 9: return Color.toskaShareCardInk.opacity(0.7)  // paper — fixed card art; must NOT follow the adaptive theme
        case 10: return Color(hex: "5a3040")             // blush
        case 11: return Color(hex: "2a4038")             // sage
        case 12: return Color(hex: "2a3548")             // frost
        case Self.customStyle:                           // custom — ink adapts to ground
            return customColorIsDark ? .white.opacity(0.85) : Color(hex: "241f2b")
        default: return .white.opacity(0.75)
        }
    }

    var accentColor: Color {
        styleHighlightColor(selectedStyle)
    }

    // MARK: - Render Full-Size Card

    @MainActor func renderCardImage(scale: CGFloat = 3.0) -> UIImage? {
        // Exact same content as the live preview (cardBody) at the full card
        // size — the exported image is byte-for-byte what the user previewed,
        // and cardBody's fittedFontSize guarantees the quote never clips.
        let fullCard = ZStack {
            cardBackground
            boundedCardDecorations
            cardGrain
            cardBody
        }
        .frame(width: cardSize.width, height: cardSize.height)
        // Pin Dynamic Type to match the preview (cardPreview pins the same):
        // ImageRenderer runs in a default environment, so without this an
        // accessibility text size would scale the card chrome in one surface
        // but not the other.
        .dynamicTypeSize(.large)
        .environment(\.colorScheme, isDarkStyle ? .dark : .light)

        let renderer = ImageRenderer(content: fullCard)
        renderer.scale = scale
        return renderer.uiImage
    }

    // MARK: - Share Functions

    /// Sets isRendering, yields one frame so SwiftUI can paint the disabled/
    /// spinner state on the share row, then runs the render+share body, then
    /// clears the flag. ImageRenderer is @MainActor so it still blocks main
    /// during the actual rasterize — this doesn't speed that up, it just
    /// guarantees the user sees feedback before the UI freezes.
    @MainActor
    private func withRenderIndicator(_ body: @escaping @MainActor () -> Void) {
        guard !isRendering else { return }
        isRendering = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 16_000_000) // ~1 frame
            body()
            isRendering = false
        }
    }

    func saveToPhotos() {
        withRenderIndicator {
            guard let image = renderCardImage() else { return }
            persistCardLook()
            // Save via PHPhotoLibrary so we can confirm ONLY on success. The old
            // UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil) passed a nil
            // completion target, so "saved to your photos" showed even when the
            // add-to-library permission was denied and nothing was actually saved.
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { success, _ in
                Task { @MainActor in
                    if success {
                        HapticManager.play(.milestone)
                        savedToPhotos = true
                        showPostShareConfirmation()
                    } else {
                        showSaveError = true
                    }
                }
            }
        }
    }

    func shareImage() {
        withRenderIndicator {
            guard let image = renderCardImage() else { return }
            persistCardLook()
            // Only show the "you shared" affirmation if the user actually shared.
            // Previously it fired unconditionally, so cancelling the system share
            // sheet still declared success — jarring on a grief app. Mirrors the
            // save-to-Photos success gate.
            //
            // When a public share page exists, the link rides along with the
            // image: recipients (and link-preview bots) land on the anonymous
            // /p/{id} page instead of a dead end. Targets that only take an
            // image (Instagram stories etc.) ignore the URL item.
            let items: [Any] = shareURL.map { [image, $0] } ?? [image]
            presentShareSheet(with: items) { completed in
                if completed {
                    Task { @MainActor in showPostShareConfirmation() }
                }
            }
        }
    }

    func showPostShareConfirmation() {
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            withAnimation(.easeIn(duration: 0.4)) {
                showSharedConfirmation = true
            }
        }
    }
}

#if DEBUG
// Harness-only construction: seeds every composer control so the matrix
// harness (ShareCardMatrixHarness) can sweep style/font/size/alignment/ratio
// through the real render path. Lives in a same-file extension so it can
// reach the private @State vars WITHOUT suppressing the memberwise init the
// production call sites use.
extension ShareCardView {
    init(text: String, handle: String, feltCount: Int, tag: String?,
         shareURL: URL? = nil, matrixStyle: Int, font: Int, size: Int,
         alignment: Int, ratio: Int, showFeltCount: Bool = true,
         customColor: Color? = nil, fragment: Set<Int> = []) {
        self.text = text
        self.handle = handle
        self.feltCount = feltCount
        self.tag = tag
        self.shareURL = shareURL
        _selectedStyle = State(initialValue: matrixStyle)
        _selectedFont = State(initialValue: font)
        _selectedSize = State(initialValue: size)
        _selectedAlignment = State(initialValue: alignment)
        _selectedRatio = State(initialValue: ratio)
        _showFeltCount = State(initialValue: showFeltCount)
        if let customColor {
            _customColor = State(initialValue: customColor)
        }
        _selectedSentences = State(initialValue: fragment)
    }

}
#endif

// MARK: - Share Button Press Style
// Tactile spring press for the platform share buttons — scales + dims briefly
// on touch so the row feels alive and clearly tappable.
struct SharePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.90 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
