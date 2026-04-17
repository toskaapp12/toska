import SwiftUI
import FirebaseAuth
import Photos

// MARK: - Share Card Style

struct ShareStyle: Identifiable {
    let id: Int
    let name: String
    let background: AnyView
    let decoration: AnyView
    let textColor: Color
    let accentColor: Color
    let isDark: Bool
}

// MARK: - Share Card View

@MainActor
struct ShareCardView: View {
    let text: String
    let handle: String
    let feltCount: Int
    let tag: String?

    @Environment(\.dismiss) var dismiss
    @State private var selectedStyle = 0
    @State private var selectedRatio = 0
    @State private var showCopied = false
    @State private var showSharedConfirmation = false
    @State private var showSavedConfirmation = false
    @State private var cardAppeared = false

    private let ratioLabels = ["9:16", "1:1", "16:9"]

    private var cardSize: CGSize {
        switch selectedRatio {
        case 0: return CGSize(width: 390, height: 690)   // story
        case 1: return CGSize(width: 390, height: 390)   // square
        case 2: return CGSize(width: 390, height: 260)   // wide
        default: return CGSize(width: 390, height: 690)
        }
    }

    // Scale the preview to fit the screen nicely
    private var previewScale: CGFloat {
        let screenW = UIScreen.main.bounds.width - 64
        return min(screenW / cardSize.width, 0.78)
    }

    // MARK: - Styles

    private var styles: [ShareStyle] {
        [
            ShareStyle(id: 0, name: "2am",
                background: AnyView(Color(hex: "08080a")),
                decoration: AnyView(bottomGlow(Color.toskaBlue, opacity: 0.04)),
                textColor: .white.opacity(0.75),
                accentColor: Color.toskaBlue,
                isDark: true),
            ShareStyle(id: 1, name: "numb",
                background: AnyView(Color(hex: "111111")),
                decoration: AnyView(EmptyView()),
                textColor: .white.opacity(0.5),
                accentColor: Color(hex: "808080"),
                isDark: true),
            ShareStyle(id: 2, name: "bruise",
                background: AnyView(LinearGradient(colors: [Color(hex: "0c0814"), Color(hex: "100a1e"), Color(hex: "08060e")], startPoint: .top, endPoint: .bottom)),
                decoration: AnyView(topGlow(Color(hex: "8b7ec8"), opacity: 0.04)),
                textColor: Color(hex: "c8c0e0").opacity(0.8),
                accentColor: Color(hex: "8b7ec8"),
                isDark: true),
            ShareStyle(id: 3, name: "ashes",
                background: AnyView(LinearGradient(colors: [Color(hex: "0e0a08"), Color(hex: "140e0c"), Color(hex: "0a0806")], startPoint: .top, endPoint: .bottom)),
                decoration: AnyView(bottomGlow(Color(hex: "c45c5c"), opacity: 0.03)),
                textColor: Color(hex: "d8c0b0").opacity(0.7),
                accentColor: Color(hex: "c45c5c"),
                isDark: true),
            ShareStyle(id: 4, name: "unsent",
                background: AnyView(LinearGradient(colors: [Color(hex: "080c14"), Color(hex: "0a1018"), Color(hex: "06080e")], startPoint: .topLeading, endPoint: .bottomTrailing)),
                decoration: AnyView(centerGlow(Color(hex: "7a97b5"), opacity: 0.03)),
                textColor: Color(hex: "b0c8e0").opacity(0.75),
                accentColor: Color(hex: "7a97b5"),
                isDark: true),
            ShareStyle(id: 5, name: "alone",
                background: AnyView(LinearGradient(colors: [Color(hex: "0e0c08"), Color(hex: "14100a"), Color(hex: "0a0806")], startPoint: .top, endPoint: .bottom)),
                decoration: AnyView(topGlow(Color(hex: "c49a6c"), opacity: 0.04)),
                textColor: Color(hex: "e0d0b8").opacity(0.7),
                accentColor: Color(hex: "c49a6c"),
                isDark: true),
            ShareStyle(id: 6, name: "hollow",
                background: AnyView(Color(hex: "060606")),
                decoration: AnyView(EmptyView()),
                textColor: .white.opacity(0.35),
                accentColor: Color(hex: "5a6a5a"),
                isDark: true),
            ShareStyle(id: 7, name: "dawn",
                background: AnyView(LinearGradient(colors: [Color(hex: "f5efe6"), Color(hex: "ece4d8"), Color(hex: "e8dfd0")], startPoint: .top, endPoint: .bottom)),
                decoration: AnyView(topGlow(Color(hex: "c9a97a"), opacity: 0.08)),
                textColor: Color(hex: "4a4035"),
                accentColor: Color(hex: "c9a97a"),
                isDark: false),
            ShareStyle(id: 8, name: "paper",
                background: AnyView(Color(hex: "f0f0ec")),
                decoration: AnyView(EmptyView()),
                textColor: Color.toskaTextDark.opacity(0.7),
                accentColor: Color(hex: "999999"),
                isDark: false),
            ShareStyle(id: 9, name: "blush",
                background: AnyView(LinearGradient(colors: [Color(hex: "f5e8ec"), Color(hex: "f0dce2"), Color(hex: "ecdae0")], startPoint: .top, endPoint: .bottom)),
                decoration: AnyView(centerGlow(Color(hex: "c47a8a"), opacity: 0.06)),
                textColor: Color(hex: "5a3040"),
                accentColor: Color(hex: "c47a8a"),
                isDark: false),
            ShareStyle(id: 10, name: "sage",
                background: AnyView(LinearGradient(colors: [Color(hex: "e8f0ec"), Color(hex: "dce8e2"), Color(hex: "d4e0da")], startPoint: .top, endPoint: .bottom)),
                decoration: AnyView(bottomGlow(Color(hex: "6ba58e"), opacity: 0.06)),
                textColor: Color(hex: "2a4038"),
                accentColor: Color(hex: "6ba58e"),
                isDark: false),
            ShareStyle(id: 11, name: "frost",
                background: AnyView(LinearGradient(colors: [Color(hex: "e8eef5"), Color(hex: "dce4f0"), Color(hex: "d4dcea")], startPoint: .top, endPoint: .bottom)),
                decoration: AnyView(topGlow(Color(hex: "7a97b5"), opacity: 0.06)),
                textColor: Color(hex: "2a3548"),
                accentColor: Color(hex: "7a97b5"),
                isDark: false),
        ]
    }

    private var currentStyle: ShareStyle {
        styles[selectedStyle]
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Color(hex: "0a0908").ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .light))
                            .foregroundColor(.white.opacity(0.3))
                    }
                    .accessibilityLabel("Close")
                    Spacer()
                    Text("share")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.4))
                    Spacer()
                    Color.clear.frame(width: 14, height: 14)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, Toska.horizontalPadding)
                .padding(.vertical, Toska.headerVerticalPadding)

                Rectangle().fill(Color.white.opacity(0.04)).frame(height: 0.5)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {
                        // Card preview
                        cardPreview
                            .frame(
                                width: cardSize.width * previewScale,
                                height: cardSize.height * previewScale
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .shadow(color: currentStyle.accentColor.opacity(0.15), radius: 40, y: 12)
                            .scaleEffect(cardAppeared ? 1 : 0.92)
                            .opacity(cardAppeared ? 1 : 0)
                            .animation(.easeOut(duration: 0.5), value: cardAppeared)
                            .padding(.top, 20)

                        // Style picker — horizontal swipe chips
                        VStack(alignment: .leading, spacing: 10) {
                            Text("MOOD")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white.opacity(0.12))
                                .tracking(2.5)
                                .padding(.horizontal, 24)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(styles) { style in
                                        Button {
                                            withAnimation(.easeInOut(duration: 0.25)) {
                                                selectedStyle = style.id
                                            }
                                        } label: {
                                            HStack(spacing: 5) {
                                                Circle()
                                                    .fill(style.accentColor)
                                                    .frame(width: 6, height: 6)
                                                Text(style.name)
                                                    .font(.system(size: 11, weight: selectedStyle == style.id ? .semibold : .regular))
                                            }
                                            .foregroundColor(selectedStyle == style.id ? style.accentColor : .white.opacity(0.2))
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 8)
                                            .background(
                                                selectedStyle == style.id
                                                    ? style.accentColor.opacity(0.1)
                                                    : Color.white.opacity(0.03)
                                            )
                                            .clipShape(Capsule())
                                            .overlay(
                                                Capsule()
                                                    .stroke(
                                                        selectedStyle == style.id
                                                            ? style.accentColor.opacity(0.2)
                                                            : Color.clear,
                                                        lineWidth: 0.5
                                                    )
                                            )
                                        }
                                    }
                                }
                                .padding(.horizontal, 24)
                            }
                        }

                        // Size picker
                        HStack(spacing: 8) {
                            ForEach(0..<ratioLabels.count, id: \.self) { index in
                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        selectedRatio = index
                                    }
                                } label: {
                                    Text(ratioLabels[index])
                                        .font(.system(size: 10, weight: selectedRatio == index ? .bold : .regular, design: .monospaced))
                                        .foregroundColor(selectedRatio == index ? .white.opacity(0.5) : .white.opacity(0.12))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 6)
                                        .background(selectedRatio == index ? Color.white.opacity(0.06) : Color.clear)
                                        .clipShape(Capsule())
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 24)

                        // Share targets
                        HStack(spacing: 0) {
                            shareTarget(name: "Stories", icon: "camera.fill", color: Color(hex: "c45c5c").opacity(0.8)) {
                                shareToInstagramStories()
                            }
                            shareTarget(name: "TikTok", icon: "play.fill", color: .white.opacity(0.5)) {
                                shareImage()
                            }
                            shareTarget(name: "X", icon: "arrow.up.right", color: .white.opacity(0.4)) {
                                shareToTwitter()
                            }
                            shareTarget(name: "iMessage", icon: "message.fill", color: Color(hex: "6ba58e").opacity(0.7)) {
                                shareImage()
                            }
                            shareTarget(name: "More", icon: "square.and.arrow.up", color: .white.opacity(0.25)) {
                                shareImage()
                            }
                        }
                        .padding(.horizontal, Toska.horizontalPadding)

                        // Action row: save to photos + copy text
                        HStack(spacing: 10) {
                            Button { saveToPhotos() } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: showSavedConfirmation ? "checkmark" : "arrow.down.to.line")
                                        .font(.system(size: 11))
                                    Text(showSavedConfirmation ? "saved" : "save to photos")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundColor(showSavedConfirmation ? Color(hex: "6ba58e").opacity(0.7) : .white.opacity(0.25))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.white.opacity(0.03))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }

                            Button {
                                UIPasteboard.general.string = "\"\(text)\"\n\n— said anonymously on toska"
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
                                    Text(showCopied ? "copied" : "copy text")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundColor(showCopied ? Color(hex: "6ba58e").opacity(0.7) : .white.opacity(0.25))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.white.opacity(0.03))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        .padding(.horizontal, 24)

                        Color.clear.frame(height: 30)
                    }
                }
            }

            // Post-share confirmation
            if showSharedConfirmation {
                Color.black.opacity(0.7).ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.3)) {
                            showSharedConfirmation = false
                        }
                    }

                VStack(spacing: 16) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 20, weight: .light))
                        .foregroundColor(.white.opacity(0.15))

                    Text("someone's going to feel less alone\nbecause of what you just shared")
                        .font(.custom("Georgia-Italic", size: 15))
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)

                    Text("the things we can't say out loud\ntravel the farthest")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.2))
                        .multilineTextAlignment(.center)

                    Button {
                        withAnimation(.easeOut(duration: 0.3)) {
                            showSharedConfirmation = false
                        }
                    } label: {
                        Text("okay")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.4))
                            .padding(.horizontal, 32)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.06))
                            .clipShape(Capsule())
                    }
                    .padding(.top, 4)
                }
                .padding(32)
                .background(Color(hex: "0e0e10"))
                .clipShape(RoundedRectangle(cornerRadius: Toska.cornerRadius))
                .padding(.horizontal, 40)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            selectedStyle = defaultStyleForTag()
            Task {
                try? await Task.sleep(nanoseconds: 100_000_000)
                cardAppeared = true
            }
        }
    }

    // MARK: - Card Preview

    var cardPreview: some View {
        ZStack {
            currentStyle.background
            currentStyle.decoration

            VStack(spacing: 0) {
                Spacer()

                if let tag = tag, selectedRatio != 2 {
                    Text(tag)
                        .font(.system(size: 8, weight: .medium))
                        .tracking(1.5)
                        .foregroundColor(currentStyle.accentColor.opacity(0.3))
                        .padding(.bottom, 12)
                }

                Text(text)
                    .font(.custom("Georgia", size: previewFontSize))
                    .foregroundColor(currentStyle.textColor)
                    .lineSpacing(previewLineSpacing)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, selectedRatio == 2 ? 20 : 30)

                Spacer()

                // Watermark
                VStack(spacing: 6) {
                    if feltCount > 0 {
                        Text("\(formatCount(feltCount)) felt this")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(currentStyle.accentColor.opacity(0.25))
                    }

                    Rectangle()
                        .fill(currentStyle.accentColor.opacity(0.08))
                        .frame(width: 20, height: 0.5)
                        .padding(.vertical, 2)

                    Text("said anonymously on toska")
                        .font(.system(size: 7, weight: .medium))
                        .tracking(0.5)
                        .foregroundColor(currentStyle.textColor.opacity(0.12))

                    Text("toska.app")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundColor(currentStyle.accentColor.opacity(0.15))
                }
                .padding(.bottom, selectedRatio == 2 ? 10 : 20)
            }
        }
        .environment(\.colorScheme, currentStyle.isDark ? .dark : .light)
    }

    // MARK: - Share Target Button

    func shareTarget(name: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .light))
                    .foregroundColor(color)
                    .frame(width: 48, height: 48)
                    .background(Color.white.opacity(0.04))
                    .clipShape(Circle())
                Text(name)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.2))
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Tag-Aware Default Style

    func defaultStyleForTag() -> Int {
        guard let tag = tag else { return 0 }
        switch tag {
        case "longing": return 0     // 2am
        case "anger": return 3       // ashes
        case "regret": return 2      // bruise
        case "acceptance": return 10 // sage
        case "confusion": return 5   // alone
        case "unsent": return 4      // unsent
        case "moving on": return 7   // dawn
        case "still love you": return 9 // blush
        default: return 0
        }
    }

    // MARK: - Font Sizing

    private var previewFontSize: CGFloat {
        let length = text.count
        if selectedRatio == 2 { return length > 200 ? 11 : 13 }
        if length > 300 { return 14 }
        if length > 150 { return 16 }
        return 18
    }

    private var previewLineSpacing: CGFloat {
        selectedRatio == 2 ? 3 : (text.count > 200 ? 5 : 7)
    }

    private var renderFontSize: CGFloat {
        let length = text.count
        if selectedRatio == 2 { return length > 200 ? 13 : 16 }
        if length > 300 { return 16 }
        if length > 150 { return 18 }
        return 22
    }

    // MARK: - Decoration Helpers

    func bottomGlow(_ color: Color, opacity: Double) -> some View {
        VStack {
            Spacer()
            Ellipse()
                .fill(RadialGradient(colors: [color.opacity(opacity), .clear], center: .center, startRadius: 0, endRadius: 180))
                .frame(width: 360, height: 200)
                .offset(y: 60)
        }
    }

    func topGlow(_ color: Color, opacity: Double) -> some View {
        VStack {
            Ellipse()
                .fill(RadialGradient(colors: [color.opacity(opacity), .clear], center: .center, startRadius: 0, endRadius: 160))
                .frame(width: 300, height: 200)
                .offset(y: -30)
            Spacer()
        }
    }

    func centerGlow(_ color: Color, opacity: Double) -> some View {
        Ellipse()
            .fill(RadialGradient(colors: [color.opacity(opacity), .clear], center: .center, startRadius: 0, endRadius: 150))
            .frame(width: 300, height: 300)
    }

    // MARK: - Render Full-Size

    @MainActor func renderCardImage() -> UIImage? {
        let style = currentStyle
        let fullCard = ZStack {
            style.background
            style.decoration

            VStack(spacing: 0) {
                Spacer()

                if let tag = tag, selectedRatio != 2 {
                    Text(tag)
                        .font(.system(size: 9, weight: .medium))
                        .tracking(1.5)
                        .foregroundColor(style.accentColor.opacity(0.3))
                        .padding(.bottom, 16)
                }

                Text(text)
                    .font(.custom("Georgia", size: renderFontSize))
                    .foregroundColor(style.textColor)
                    .lineSpacing(previewLineSpacing + 1)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, selectedRatio == 2 ? 26 : 38)

                Spacer()

                VStack(spacing: 7) {
                    if feltCount > 0 {
                        Text("\(formatCount(feltCount)) felt this")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(style.accentColor.opacity(0.25))
                    }

                    Rectangle()
                        .fill(style.accentColor.opacity(0.08))
                        .frame(width: 24, height: 0.5)
                        .padding(.vertical, 2)

                    Text("said anonymously on toska")
                        .font(.system(size: 8, weight: .medium))
                        .tracking(0.5)
                        .foregroundColor(style.textColor.opacity(0.12))

                    Text("toska.app")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(style.accentColor.opacity(0.18))
                }
                .padding(.bottom, selectedRatio == 2 ? 14 : 28)
            }
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .environment(\.colorScheme, style.isDark ? .dark : .light)

        let renderer = ImageRenderer(content: fullCard)
        renderer.scale = 3.0
        return renderer.uiImage
    }

    // MARK: - Share Functions

    func shareImage() {
        guard let image = renderCardImage() else { return }
        presentShareSheet(with: [image])
        showPostShareConfirmation()
    }

    func saveToPhotos() {
        guard let image = renderCardImage() else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            if status == .authorized || status == .limited {
                UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                Task { @MainActor in
                    HapticManager.play(.feltThis)
                    showSavedConfirmation = true
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    showSavedConfirmation = false
                }
            }
        }
    }

    func shareToInstagramStories() {
        guard let image = renderCardImage() else { return }
        guard let imageData = image.pngData() else { return }

        let bgColor = currentStyle.isDark ? "#0a0908" : "#f0f0ec"
        let pasteboardItems: [String: Any] = [
            "com.instagram.sharedSticker.backgroundImage": imageData,
            "com.instagram.sharedSticker.backgroundTopColor": bgColor,
            "com.instagram.sharedSticker.backgroundBottomColor": bgColor
        ]
        let pasteboardOptions: [UIPasteboard.OptionsKey: Any] = [
            .expirationDate: Date().addingTimeInterval(300)
        ]
        UIPasteboard.general.setItems([pasteboardItems], options: pasteboardOptions)

        if let url = URL(string: "instagram-stories://share"), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
            showPostShareConfirmation()
        } else {
            shareImage()
        }
    }

    func shareToTwitter() {
        let tweetText = "\"\(text)\"\n\n— said anonymously on toska"
        guard let image = renderCardImage() else { return }
        presentShareSheet(with: [tweetText, image])
        showPostShareConfirmation()
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
