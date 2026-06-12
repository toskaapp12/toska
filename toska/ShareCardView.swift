import SwiftUI
import FirebaseAuth

@MainActor
struct ShareCardView: View {
    let text: String
    let handle: String
    let feltCount: Int
    let tag: String?

    @Environment(\.dismiss) var dismiss
    @State private var selectedStyle = 0
    @State private var selectedFont = 0
    @State private var selectedSize = 1
    @State private var selectedAlignment = 1
    @State private var selectedRatio = 0
    // User-toggleable: show or hide the "X felt this" line on the share card.
    // Defaults to true (matches previous always-on-when-> 0 behavior), but
    // users sharing a post they want to feel less performative can hide it.
    @State private var showFeltCount = true
    @State private var showCopied = false
    @State private var showSharedConfirmation = false
    @State private var sharedPlatform = ""
    @State private var savedToPhotos = false
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

                Rectangle().fill(Color.black.opacity(0.10)).frame(height: 0.5)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        cardPreview
                            .frame(width: min(cardSize.width * 0.75, 292), height: min(cardSize.height * 0.75, 518))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            // A clear hairline + layered shadow so the card always
                            // separates from the sheet, whether it's a dark or a
                            // light mood (was a near-invisible 2pt radius on black).
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(.white.opacity(0.14), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.55), radius: 26, y: 14)
                            .shadow(color: cardGlowColor.opacity(0.30), radius: 34, y: 6)
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

                        // MARK: - Ratio + felt-count
                        HStack(spacing: 10) {
                            ratioControl

                            if feltCount > 0 {
                                Spacer(minLength: 8)
                                feltCountPill
                            } else {
                                Spacer(minLength: 0)
                            }
                        }
                        .padding(.horizontal, 20)

                        // MARK: - Share Buttons
                        // Solid, vibrant, recognizable destination buttons — the
                        // whole point of this screen is getting cards OUT into the
                        // world, so the share row is the loudest thing here.
                        // Instagram Stories (the biggest driver) gets the real IG
                        // gradient; the rest use their platform colors.
                        HStack(spacing: 0) {
                            platformButton(name: "Save", icon: "arrow.down.to.line",
                                           colors: [Color.toskaAccentGold, Color(hex: "b8893f")]) {
                                saveToPhotos()
                            }
                            platformButton(name: "Stories", icon: "camera.fill",
                                           colors: [Color(hex: "FEDA75"), Color(hex: "FA7E1E"), Color(hex: "D62976"), Color(hex: "962FBF")]) {
                                shareToInstagramStories()
                            }
                            // TikTok accepts images via the iOS system share sheet,
                            // so route through the same path as "More" (shareImage)
                            // with the platform tagged — tapping it presents the
                            // share sheet where TikTok appears as a destination.
                            platformButton(name: "TikTok", icon: "music.note",
                                           colors: [Color(hex: "010101"), Color(hex: "161616")]) {
                                sharedPlatform = "TikTok"
                                shareImage()
                            }
                            platformButton(name: "X", icon: "arrow.up.right",
                                           colors: [Color(hex: "2b2b2e"), Color(hex: "111113")]) {
                                shareToTwitter()
                            }
                            platformButton(name: "iMessage", icon: "message.fill",
                                           colors: [Color(hex: "37D14A"), Color(hex: "26A938")]) {
                                sharedPlatform = "iMessage"
                                shareImage()
                            }
                            platformButton(name: "More", icon: "square.and.arrow.up",
                                           colors: [Color.toskaMidnightPurple, Color(hex: "6E5FB0")]) {
                                sharedPlatform = ""
                                shareImage()
                            }
                        }
                        .disabled(isRendering)
                        .opacity(isRendering ? 0.5 : 1)
                        .overlay(alignment: .center) {
                            if isRendering {
                                ProgressView().tint(Color(hex: "1a1720").opacity(0.6))
                            }
                        }
                        .padding(.horizontal, 16)

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
                            HStack(spacing: 5) {
                                Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 10))
                                Text(showCopied ? "copied" : "copy text")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundColor(showCopied ? Color.toskaFollowGreen.opacity(0.85) : Color(hex: "8a8790"))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.black.opacity(0.04))
                            .cornerRadius(6)
                        }
                        .padding(.horizontal, 24)

                        Color.clear.frame(height: 30)
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
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.2))
                        .multilineTextAlignment(.center)

                    Button {
                        withAnimation(.easeOut(duration: 0.3)) {
                            showSharedConfirmation = false
                            savedToPhotos = false
                        }
                    } label: {
                        Text("okay")
                            .font(.system(size: 12, weight: .medium))
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
            HStack(spacing: 10) {
                ForEach(0..<styles.count, id: \.self) { index in
                    let isSelected = selectedStyle == index
                    Button {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            selectedStyle = index
                        }
                    } label: {
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.clear)
                                .frame(width: 46, height: 46)
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
                                .font(.system(size: 8, weight: isSelected ? .semibold : .regular))
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
                        .font(.system(size: 9, weight: .medium))
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
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.04))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.black.opacity(0.10), lineWidth: 0.5)
        )
        .padding(.horizontal, 20)
    }

    private var toolbarDivider: some View {
        Rectangle().fill(Color.black.opacity(0.10)).frame(width: 0.5, height: 18)
    }

    /// Clean segmented control for the card ratio.
    private var ratioControl: some View {
        HStack(spacing: 2) {
            ForEach(0..<ratios.count, id: \.self) { index in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { selectedRatio = index }
                } label: {
                    Text(ratios[index])
                        .font(.system(size: 10, weight: selectedRatio == index ? .semibold : .regular))
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
                    .font(.system(size: 10, weight: showFeltCount ? .medium : .regular))
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

    // MARK: - Platform Button

    func platformButton(name: String, icon: String, colors: [Color], action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 50, height: 50)
                    .background(
                        Circle().fill(
                            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                    )
                    .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 0.75))
                    .shadow(color: colors.first?.opacity(0.45) ?? .clear, radius: 9, y: 4)
                Text(name)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(hex: "1a1720"))
            }
            .frame(maxWidth: .infinity)
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

    var cardPreview: some View {
        ZStack {
            cardBackground
            cardDecorations

            VStack(spacing: 0) {
                // Vertically CENTERED in the card (equal spacers) — the quote
                // sits dead-center, the attribution pinned below.
                Spacer(minLength: 0).frame(maxHeight: .infinity)

                if let tag = tag, selectedRatio != 2 {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(accentColor.opacity(0.4))
                            .frame(width: 4, height: 4)
                        Text(tag)
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(1)
                            .foregroundColor(accentColor.opacity(0.5))
                    }
                    .padding(.bottom, 14)
                }

                Text(quoteMark)
                    .font(.custom("Georgia", size: selectedRatio == 2 ? 24 : 34))
                    .foregroundColor(accentColor.opacity(isDarkStyle ? 0.18 : 0.14))
                    .padding(.bottom, 2)

                Text(text)
                    .font(quoteFont(size: fontSize))
                    .foregroundColor(textColor)
                    .lineSpacing(lineSpacing)
                    .multilineTextAlignment(textAlignment)
                    .padding(.horizontal, textPadding)

                Spacer(minLength: 0).frame(maxHeight: .infinity)

                VStack(spacing: 6) {
                    if feltCount > 0 && showFeltCount {
                        Text("\(formatCount(feltCount)) felt this")
                            .font(.system(size: 9, weight: .medium))
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
                    // Website URL removed from the share card — felt out of
                    // place under the brand mark for a screenshot people post
                    // to IG / Twitter / TikTok. The "toska" wordmark above is
                    // enough attribution.
                }
                .padding(.bottom, selectedRatio == 2 ? 10 : 20)
            }
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

    var fontSize: CGFloat {
        let length = text.count
        let base: CGFloat
        if selectedRatio == 2 {
            base = length > 200 ? 11 : 13
        } else if length > 300 {
            base = 14
        } else if length > 150 {
            base = 16
        } else {
            base = 18
        }
        return base * sizeMultiplier
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
        case 9: return Color.toskaTextDark.opacity(0.7)  // paper
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
        let fullCard = ZStack {
            cardBackground
            cardDecorations

            VStack(spacing: 0) {
                Spacer(minLength: 0).frame(maxHeight: .infinity)

                if let tag = tag, selectedRatio != 2 {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(accentColor.opacity(0.4))
                            .frame(width: 5, height: 5)
                        Text(tag)
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(1)
                            .foregroundColor(accentColor.opacity(0.5))
                    }
                    .padding(.bottom, 16)
                }

                Text(quoteMark)
                    .font(.custom("Georgia", size: selectedRatio == 2 ? 28 : 40))
                    .foregroundColor(accentColor.opacity(isDarkStyle ? 0.18 : 0.14))
                    .padding(.bottom, 2)

                Text(text)
                    .font(quoteFont(size: renderFontSize))
                    .foregroundColor(textColor)
                    .lineSpacing(lineSpacing + 1)
                    .multilineTextAlignment(textAlignment)
                    .padding(.horizontal, selectedRatio == 2 ? 26 : 38)

                Spacer(minLength: 0).frame(maxHeight: .infinity)

                VStack(spacing: 7) {
                    if feltCount > 0 && showFeltCount {
                        Text("\(formatCount(feltCount)) felt this")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(accentColor.opacity(0.35))
                    }

                    Rectangle()
                        .fill(accentColor.opacity(isDarkStyle ? 0.1 : 0.08))
                        .frame(width: 28, height: 0.5)
                        .padding(.vertical, 3)

                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(accentColor.opacity(isDarkStyle ? 0.12 : 0.08))
                            .frame(width: 18, height: 18)
                            .overlay(
                                Text("t")
                                    .font(.custom("Georgia-Italic", size: 13))
                                    .foregroundColor(isDarkStyle ? .white.opacity(0.5) : brandTextColor.opacity(0.4))
                            )
                        Text("toska")
                            .font(.custom("Georgia-Italic", size: 14))
                            .foregroundColor(isDarkStyle ? .white.opacity(0.25) : brandTextColor.opacity(0.3))
                    }
                    // Website URL removed from the rendered share image —
                    // see the preview layout above.
                }
                .padding(.bottom, selectedRatio == 2 ? 14 : 26)
            }
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .environment(\.colorScheme, isDarkStyle ? .dark : .light)

        let renderer = ImageRenderer(content: fullCard)
        renderer.scale = 3.0
        return renderer.uiImage
    }

    var renderFontSize: CGFloat {
        let length = text.count
        let base: CGFloat
        if selectedRatio == 2 {
            base = length > 200 ? 13 : 16
        } else if length > 300 {
            base = 16
        } else if length > 150 {
            base = 18
        } else {
            base = 22
        }
        return base * sizeMultiplier
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
            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
            HapticManager.play(.milestone)
            savedToPhotos = true
            showPostShareConfirmation()
        }
    }

    func shareImage() {
        withRenderIndicator {
            guard let image = renderCardImage() else { return }
            presentShareSheet(with: [image])
            showPostShareConfirmation()
        }
    }

    func shareToInstagramStories() {
        withRenderIndicator {
            guard let image = renderCardImage() else { return }
            guard let imageData = image.pngData() else { return }

            let bgColor = isDarkStyle ? "#0a0908" : "#f0f0ec"
            let pasteboardItems: [String: Any] = [
                "com.instagram.sharedSticker.backgroundImage": imageData,
                "com.instagram.sharedSticker.backgroundTopColor": bgColor,
                "com.instagram.sharedSticker.backgroundBottomColor": bgColor
            ]

            // C-1 (2026-06-11): mirror the copy-text path — .localOnly keeps the
            // rendered grief-text image off Universal Clipboard (no cross-device
            // sync). Instagram reads the pasteboard locally on this device, so the
            // handoff is unaffected.
            let pasteboardOptions: [UIPasteboard.OptionsKey: Any] = [
                .expirationDate: Date().addingTimeInterval(300),
                .localOnly: true
            ]

            UIPasteboard.general.setItems([pasteboardItems], options: pasteboardOptions)

            if let url = URL(string: "instagram-stories://share"), UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
                sharedPlatform = "Instagram"
                showPostShareConfirmation()
            } else {
                // Nested withRenderIndicator is a no-op because isRendering is
                // still true; inline the fallback so we actually present.
                guard let fallbackImage = renderCardImage() else { return }
                presentShareSheet(with: [fallbackImage])
                showPostShareConfirmation()
            }
        }
    }

    func shareToTwitter() {
        withRenderIndicator {
            let tweetText = "\"\(text)\"\n\n— someone on toska"
            guard let image = renderCardImage() else { return }
            presentShareSheet(with: [tweetText, image])
            sharedPlatform = "X"
            showPostShareConfirmation()
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
