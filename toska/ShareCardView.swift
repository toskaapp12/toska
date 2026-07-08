import SwiftUI
import UIKit
import Photos
import FirebaseAuth

@MainActor
struct ShareCardView: View {
    let text: String
    let handle: String
    let feltCount: Int
    let tag: String?

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
    @State private var showCopied = false
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
    let fonts = ["serif", "sans", "mono", "hand"]
    let ratios = ["story", "square", "wide"]

    /// Explicit dark-mood index set. Dark moods: 0...7 (2am, dusk, numb, bruise,
    /// ashes, unsent, alone, hollow); light moods: 8...12 (dawn, paper, blush,
    /// sage, frost). Replaces the brittle `selectedStyle < 7` cutoff so inserting
    /// a mood can't silently flip a card's color scheme.
    func isDark(_ index: Int) -> Bool { index <= 7 }

    var cardSize: CGSize {
        switch selectedRatio {
        case 0: return CGSize(width: 390, height: 690)
        case 1: return CGSize(width: 390, height: 390)
        case 2: return CGSize(width: 390, height: 260)
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

                        // MARK: - Copy Text
                        Button {
                            // N-6 (2026-06-09 re-review): grief text copied to the
                            // pasteboard must not linger or sync off-device. Mirror
                            // the image-share path's options — auto-expire after 5
                            // min and keep it local (no Universal Clipboard hand-off
                            // to the user's other Apple devices).
                            UIPasteboard.general.setItems(
                                [["public.utf8-plain-text": "\"\(text)\"\n\n— someone on toska"]],
                                options: [
                                    .expirationDate: Date().addingTimeInterval(300),
                                    .localOnly: true,
                                ]
                            )
                            showCopied = true
                            HapticManager.play(.feltThis)
                            Task {
                                try? await Task.sleep(nanoseconds: 2_000_000_000)
                                showCopied = false
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 11))
                                Text(showCopied ? "copied" : "copy text instead")
                                    .font(ToskaFont.sans(11, weight: .medium))
                            }
                            // Quiet tertiary text link (no grey box) so the Save/Share
                            // pills stay the clear primary actions.
                            .foregroundColor(showCopied ? Color.toskaFollowGreen.opacity(0.9) : Color(hex: "8a8790"))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                        }
                        .padding(.horizontal, 24)

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
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 4)
        }
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

    func fontPickerFont(_ index: Int) -> Font {
        switch index {
        case 0: return .custom("Georgia-Italic", size: 10)
        case 1: return .system(size: 10, weight: .medium)
        case 2: return .system(size: 10, weight: .regular, design: .monospaced)
        case 3: return .system(size: 10, weight: .regular, design: .serif)
        default: return .system(size: 10)
        }
    }

    func quoteFont(size: CGFloat) -> Font {
        switch selectedFont {
        case 0: return .custom("Georgia", size: size)
        case 1: return .system(size: size, weight: .light)
        case 2: return .system(size: size, weight: .regular, design: .monospaced)
        case 3: return .custom("Georgia-Italic", size: size)
        default: return .custom("Georgia", size: size)
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

            if let tag, !tag.isEmpty, selectedRatio != 2 {
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
                .font(.custom("Georgia", size: selectedRatio == 2 ? 24 : 34))
                .foregroundColor(accentColor.opacity(isDarkStyle ? 0.18 : 0.14))
                .padding(.bottom, 2)

            Text(text)
                .font(quoteFont(size: fittedFontSize))
                .foregroundColor(textColor)
                .lineSpacing(lineSpacing)
                .multilineTextAlignment(textAlignment)
                // fittedFontSize already MEASURED that the text fits within
                // quoteMaxHeight (to 96%); the minimumScaleFactor is a final
                // belt-and-suspenders against any SwiftUI-vs-UIKit rounding so a
                // long message can NEVER clip — the whole point of this rewrite.
                .minimumScaleFactor(0.7)
                .padding(.horizontal, textPadding)
                .frame(maxHeight: quoteMaxHeight)

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
                                .font(.custom("Georgia-Italic", size: 10))
                                .foregroundColor(isDarkStyle ? .white.opacity(0.5) : brandTextColor.opacity(0.4))
                        )
                    Text("toska")
                        .font(.custom("Georgia-Italic", size: 12))
                        .foregroundColor(isDarkStyle ? .white.opacity(0.25) : brandTextColor.opacity(0.3))
                }
            }
            .padding(.bottom, selectedRatio == 2 ? 10 : 20)
        }
    }

    var cardPreview: some View {
        ZStack {
            cardBackground
            cardDecorations
            cardBody
        }
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
        cardSize.height - (selectedRatio == 2 ? 120 : 215)
    }

    /// Largest font the card would ever use (short posts). The fit search below
    /// scales DOWN from here for longer text. Wide cards get a smaller ceiling
    /// (least vertical room). `sizeMultiplier` applies the user's size control.
    var maxFontSize: CGFloat { (selectedRatio == 2 ? 20 : 24) * sizeMultiplier }

    /// The font size the quote is ACTUALLY drawn at — computed by MEASURING the
    /// text (UIKit boundingRect) and binary-searching the largest point size at
    /// which it fits within the quote box (width = card − 2·padding, height =
    /// quoteMaxHeight). This replaces the old coarse length-bucket heuristic +
    /// minimumScaleFactor, which could still CLIP a long message (the scale
    /// factor bottoms out for multiline height-fitting). The SAME value drives
    /// the live preview AND the exported image, so they're byte-for-byte WYSIWYG.
    var fittedFontSize: CGFloat {
        guard !text.isEmpty else { return maxFontSize }
        let maxW = cardSize.width - 2 * textPadding
        // Fit to 96% of the box: a small safety margin so any SwiftUI-vs-UIKit
        // sub-pixel layout difference can't tip a fitted size into a clip.
        let maxH = quoteMaxHeight * 0.96
        var lo: CGFloat = 8, hi = maxFontSize, best: CGFloat = 8
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

    private func measuringUIFont(size: CGFloat) -> UIFont {
        switch selectedFont {
        case 1: return .systemFont(ofSize: size, weight: .light)
        case 2: return .monospacedSystemFont(ofSize: size, weight: .regular)
        case 3: return UIFont(name: "Georgia-Italic", size: size) ?? .italicSystemFont(ofSize: size)
        default: return UIFont(name: "Georgia", size: size) ?? .systemFont(ofSize: size)
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
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: measuringUIFont(size: fontSize), .paragraphStyle: para],
            context: nil
        )
        return ceil(rect.height)
    }

    var lineSpacing: CGFloat {
        let base: CGFloat = selectedRatio == 2 ? 3 : (text.count > 200 ? 5 : 7)
        return base * sizeMultiplier
    }

    var textPadding: CGFloat {
        selectedRatio == 2 ? 20 : 30
    }

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
        default: return .white.opacity(0.75)
        }
    }

    var accentColor: Color {
        styleHighlightColor(selectedStyle)
    }

    // MARK: - Render Full-Size Card

    @MainActor func renderCardImage() -> UIImage? {
        // Exact same content as the live preview (cardBody) at the full card
        // size — the exported image is byte-for-byte what the user previewed,
        // and cardBody's fittedFontSize guarantees the quote never clips.
        let fullCard = ZStack {
            cardBackground
            cardDecorations
            cardBody
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .environment(\.colorScheme, isDarkStyle ? .dark : .light)

        let renderer = ImageRenderer(content: fullCard)
        renderer.scale = 3.0
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
            // Only show the "you shared" affirmation if the user actually shared.
            // Previously it fired unconditionally, so cancelling the system share
            // sheet still declared success — jarring on a grief app. Mirrors the
            // save-to-Photos success gate.
            presentShareSheet(with: [image]) { completed in
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
