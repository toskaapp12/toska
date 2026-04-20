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
    @State private var selectedRatio = 0
    @State private var showCopied = false
    @State private var showSharedConfirmation = false
    @State private var sharedPlatform = ""
    @State private var savedToPhotos = false

    let styles = ["2am", "numb", "bruise", "ashes", "unsent", "alone", "hollow", "dawn", "paper", "blush", "sage", "frost"]
    let fonts = ["serif", "sans", "mono", "hand"]
    let ratios = ["story", "square", "wide"]

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
            Color(hex: "0a0908").ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .light))
                            .foregroundColor(.white.opacity(0.3))
                    }
                    Spacer()
                    Text("share this")
                        .font(.custom("Georgia-Italic", size: 13))
                        .foregroundColor(.white.opacity(0.3))
                    Spacer()
                    Image(systemName: "xmark")
                        .font(.system(size: 14))
                        .foregroundColor(.clear)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Rectangle().fill(Color.white.opacity(0.04)).frame(height: 0.5)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        cardPreview
                            .frame(width: min(cardSize.width * 0.75, 292), height: min(cardSize.height * 0.75, 518))
                            .cornerRadius(2)
                            .shadow(color: cardGlowColor.opacity(0.12), radius: 30, y: 10)
                            .padding(.top, 16)

                        // MARK: - Mood Picker
                        VStack(alignment: .leading, spacing: 8) {
                            Text("MOOD")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.white.opacity(0.15))
                                .tracking(2.5)
                                .padding(.horizontal, 24)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 5) {
                                    ForEach(0..<styles.count, id: \.self) { index in
                                        Button {
                                            withAnimation(.easeInOut(duration: 0.3)) {
                                                selectedStyle = index
                                            }
                                        } label: {
                                            Text(styles[index])
                                                .font(.system(size: 10, weight: selectedStyle == index ? .bold : .regular))
                                                .foregroundColor(selectedStyle == index ? styleHighlightColor(index) : .white.opacity(0.2))
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 6)
                                                .background(selectedStyle == index ? styleHighlightColor(index).opacity(0.1) : Color.clear)
                                                .cornerRadius(4)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 4)
                                                        .stroke(selectedStyle == index ? styleHighlightColor(index).opacity(0.2) : Color.clear, lineWidth: 0.5)
                                                )
                                        }
                                    }
                                }
                                .padding(.horizontal, 24)
                            }
                        }

                        // MARK: - Font Picker
                        VStack(alignment: .leading, spacing: 8) {
                            Text("FONT")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.white.opacity(0.15))
                                .tracking(2.5)
                                .padding(.horizontal, 24)

                            HStack(spacing: 5) {
                                ForEach(0..<fonts.count, id: \.self) { index in
                                    Button {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            selectedFont = index
                                        }
                                    } label: {
                                        Text(fonts[index])
                                            .font(fontPickerFont(index))
                                            .foregroundColor(selectedFont == index ? .white.opacity(0.6) : .white.opacity(0.15))
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 6)
                                            .background(selectedFont == index ? Color.white.opacity(0.08) : Color.clear)
                                            .cornerRadius(4)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 24)
                        }

                        // MARK: - Size Picker
                        HStack(spacing: 6) {
                            ForEach(0..<ratios.count, id: \.self) { index in
                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        selectedRatio = index
                                    }
                                } label: {
                                    Text(ratios[index])
                                        .font(.system(size: 9, weight: selectedRatio == index ? .bold : .regular))
                                        .foregroundColor(selectedRatio == index ? .white.opacity(0.5) : .white.opacity(0.15))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 5)
                                        .background(selectedRatio == index ? Color.white.opacity(0.06) : Color.clear)
                                        .cornerRadius(4)
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 24)

                        // MARK: - Share Buttons
                        HStack(spacing: 0) {
                            platformButton(name: "Save", icon: "arrow.down.to.line", color: Color(hex: "c9a97a").opacity(0.8)) {
                                saveToPhotos()
                            }
                            platformButton(name: "Stories", icon: "camera.fill", color: Color(hex: "c45c5c").opacity(0.8)) {
                                shareToInstagramStories()
                            }
                            platformButton(name: "X", icon: "arrow.up.right", color: .white.opacity(0.5)) {
                                shareToTwitter()
                            }
                            platformButton(name: "iMessage", icon: "message.fill", color: Color(hex: "6ba58e").opacity(0.7)) {
                                sharedPlatform = "iMessage"
                                shareImage()
                            }
                            platformButton(name: "More", icon: "square.and.arrow.up", color: .white.opacity(0.3)) {
                                sharedPlatform = ""
                                shareImage()
                            }
                        }
                        .padding(.horizontal, 16)

                        // MARK: - Copy Text
                        Button {
                            UIPasteboard.general.string = "\"\(text)\"\n\n— someone on toska\ntoskaapp.com"
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
                            .foregroundColor(showCopied ? Color(hex: "6ba58e").opacity(0.7) : .white.opacity(0.2))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.03))
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
        .preferredColorScheme(.dark)
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

    func platformButton(name: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .light))
                    .foregroundColor(color)
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(22)
                Text(name)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(.white.opacity(0.2))
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Style Helpers

    func styleHighlightColor(_ index: Int) -> Color {
        switch index {
        case 0: return Color.toskaBlue
        case 1: return Color(hex: "808080")
        case 2: return Color(hex: "8b7ec8")
        case 3: return Color(hex: "c45c5c")
        case 4: return Color(hex: "7a97b5")
        case 5: return Color(hex: "c49a6c")
        case 6: return Color(hex: "5a6a5a")
        case 7: return Color(hex: "c9a97a")
        case 8: return Color(hex: "999999")
        case 9: return Color(hex: "c47a8a")
        case 10: return Color(hex: "6ba58e")
        case 11: return Color(hex: "7a97b5")
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
                Spacer()

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
                    .font(.custom("Georgia", size: selectedRatio == 2 ? 24 : 32))
                    .foregroundColor(accentColor.opacity(isDarkStyle ? 0.15 : 0.12))
                    .padding(.bottom, 2)

                Text(text)
                    .font(quoteFont(size: fontSize))
                    .foregroundColor(textColor)
                    .lineSpacing(lineSpacing)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, textPadding)

                Spacer()

                VStack(spacing: 6) {
                    if feltCount > 0 {
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

                    Text("toskaapp.com")
                        .font(.system(size: 7, weight: .medium))
                        .tracking(1)
                        .foregroundColor(isDarkStyle ? .white.opacity(0.1) : brandTextColor.opacity(0.15))
                }
                .padding(.bottom, selectedRatio == 2 ? 10 : 20)
            }
        }
    }

    var quoteMark: String { "\u{201C}" }

    var isDarkStyle: Bool { selectedStyle < 7 }

    var brandTextColor: Color {
        switch selectedStyle {
        case 7: return Color(hex: "4a4035")
        case 8: return Color(hex: "333333")
        case 9: return Color(hex: "5a3040")
        case 10: return Color(hex: "2a4038")
        case 11: return Color(hex: "2a3548")
        default: return Color(hex: "333333")
        }
    }

    var fontSize: CGFloat {
        let length = text.count
        if selectedRatio == 2 {
            return length > 200 ? 11 : 13
        }
        if length > 300 { return 14 }
        if length > 150 { return 16 }
        return 18
    }

    var lineSpacing: CGFloat {
        selectedRatio == 2 ? 3 : (text.count > 200 ? 5 : 7)
    }

    var textPadding: CGFloat {
        selectedRatio == 2 ? 20 : 30
    }

    // MARK: - Card Backgrounds

    var cardBackground: some View {
        Group {
            switch selectedStyle {
            case 0: Color(hex: "08080a")
            case 1: Color(hex: "111111")
            case 2: LinearGradient(colors: [Color(hex: "0c0814"), Color(hex: "100a1e"), Color(hex: "08060e")], startPoint: .top, endPoint: .bottom)
            case 3: LinearGradient(colors: [Color(hex: "0e0a08"), Color(hex: "140e0c"), Color(hex: "0a0806")], startPoint: .top, endPoint: .bottom)
            case 4: LinearGradient(colors: [Color(hex: "080c14"), Color(hex: "0a1018"), Color(hex: "06080e")], startPoint: .topLeading, endPoint: .bottomTrailing)
            case 5: LinearGradient(colors: [Color(hex: "0e0c08"), Color(hex: "14100a"), Color(hex: "0a0806")], startPoint: .top, endPoint: .bottom)
            case 6: Color(hex: "060606")
            case 7: LinearGradient(colors: [Color(hex: "f5efe6"), Color(hex: "ece4d8"), Color(hex: "e8dfd0")], startPoint: .top, endPoint: .bottom)
            case 8: Color(hex: "f0f0ec")
            case 9: LinearGradient(colors: [Color(hex: "f5e8ec"), Color(hex: "f0dce2"), Color(hex: "ecdae0")], startPoint: .top, endPoint: .bottom)
            case 10: LinearGradient(colors: [Color(hex: "e8f0ec"), Color(hex: "dce8e2"), Color(hex: "d4e0da")], startPoint: .top, endPoint: .bottom)
            case 11: LinearGradient(colors: [Color(hex: "e8eef5"), Color(hex: "dce4f0"), Color(hex: "d4dcea")], startPoint: .top, endPoint: .bottom)
            default: Color(hex: "08080a")
            }
        }
    }

    // MARK: - Card Decorations

    var cardDecorations: some View {
        Group {
            switch selectedStyle {
            case 0:
                VStack {
                    Spacer()
                    Ellipse()
                        .fill(RadialGradient(colors: [Color.toskaBlue.opacity(0.04), Color.clear], center: .center, startRadius: 0, endRadius: 180))
                        .frame(width: 360, height: 200)
                        .offset(y: 60)
                }
            case 2:
                VStack {
                    Ellipse()
                        .fill(RadialGradient(colors: [Color(hex: "8b7ec8").opacity(0.04), Color.clear], center: .center, startRadius: 0, endRadius: 160))
                        .frame(width: 300, height: 200)
                        .offset(y: -30)
                    Spacer()
                }
            case 3:
                VStack {
                    Spacer()
                    Ellipse()
                        .fill(RadialGradient(colors: [Color(hex: "c45c5c").opacity(0.03), Color.clear], center: .center, startRadius: 0, endRadius: 140))
                        .frame(width: 280, height: 180)
                        .offset(y: 40)
                }
            case 4:
                Ellipse()
                    .fill(RadialGradient(colors: [Color(hex: "7a97b5").opacity(0.03), Color.clear], center: .center, startRadius: 0, endRadius: 150))
                    .frame(width: 300, height: 300)
            case 5:
                VStack {
                    Ellipse()
                        .fill(RadialGradient(colors: [Color(hex: "c49a6c").opacity(0.04), Color.clear], center: .center, startRadius: 0, endRadius: 120))
                        .frame(width: 240, height: 240)
                        .offset(y: 30)
                    Spacer()
                }
            case 7:
                VStack {
                    Ellipse()
                        .fill(RadialGradient(colors: [Color(hex: "c9a97a").opacity(0.08), Color.clear], center: .center, startRadius: 0, endRadius: 160))
                        .frame(width: 300, height: 250)
                        .offset(y: -20)
                    Spacer()
                }
            case 9:
                Ellipse()
                    .fill(RadialGradient(colors: [Color(hex: "c47a8a").opacity(0.06), Color.clear], center: .center, startRadius: 0, endRadius: 140))
                    .frame(width: 280, height: 280)
            case 10:
                VStack {
                    Spacer()
                    Ellipse()
                        .fill(RadialGradient(colors: [Color(hex: "6ba58e").opacity(0.06), Color.clear], center: .center, startRadius: 0, endRadius: 150))
                        .frame(width: 300, height: 200)
                        .offset(y: 50)
                }
            case 11:
                VStack {
                    Ellipse()
                        .fill(RadialGradient(colors: [Color(hex: "7a97b5").opacity(0.06), Color.clear], center: .center, startRadius: 0, endRadius: 150))
                        .frame(width: 280, height: 220)
                        .offset(y: -30)
                    Spacer()
                }
            default:
                EmptyView()
            }
        }
    }

    // MARK: - Style Colors

    var textColor: Color {
        switch selectedStyle {
        case 0: return .white.opacity(0.75)
        case 1: return .white.opacity(0.5)
        case 2: return Color(hex: "c8c0e0").opacity(0.8)
        case 3: return Color(hex: "d8c0b0").opacity(0.7)
        case 4: return Color(hex: "b0c8e0").opacity(0.75)
        case 5: return Color(hex: "e0d0b8").opacity(0.7)
        case 6: return .white.opacity(0.35)
        case 7: return Color(hex: "4a4035")
        case 8: return Color.toskaTextDark.opacity(0.7)
        case 9: return Color(hex: "5a3040")
        case 10: return Color(hex: "2a4038")
        case 11: return Color(hex: "2a3548")
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
                Spacer()

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
                    .font(.custom("Georgia", size: selectedRatio == 2 ? 28 : 38))
                    .foregroundColor(accentColor.opacity(isDarkStyle ? 0.15 : 0.12))
                    .padding(.bottom, 2)

                Text(text)
                    .font(quoteFont(size: renderFontSize))
                    .foregroundColor(textColor)
                    .lineSpacing(lineSpacing + 1)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, selectedRatio == 2 ? 26 : 38)

                Spacer()

                VStack(spacing: 7) {
                    if feltCount > 0 {
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

                    Text("toskaapp.com")
                        .font(.system(size: 8, weight: .medium))
                        .tracking(1.2)
                        .foregroundColor(isDarkStyle ? .white.opacity(0.12) : brandTextColor.opacity(0.18))
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
        if selectedRatio == 2 {
            return length > 200 ? 13 : 16
        }
        if length > 300 { return 16 }
        if length > 150 { return 18 }
        return 22
    }

    // MARK: - Share Functions

    func saveToPhotos() {
        guard let image = renderCardImage() else { return }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        HapticManager.play(.success)
        savedToPhotos = true
        showPostShareConfirmation()
    }

    func shareImage() {
        guard let image = renderCardImage() else { return }
        presentShareSheet(with: [image])
        showPostShareConfirmation()
    }

    func shareToInstagramStories() {
        guard let image = renderCardImage() else { return }
        guard let imageData = image.pngData() else { return }

        let bgColor = isDarkStyle ? "#0a0908" : "#f0f0ec"
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
            sharedPlatform = "Instagram"
            showPostShareConfirmation()
        } else {
            shareImage()
        }
    }

    func shareToTwitter() {
        let tweetText = "\"\(text)\"\n\n— someone on toska\ntoskaapp.com"
        guard let image = renderCardImage() else { return }
        presentShareSheet(with: [tweetText, image])
        sharedPlatform = "X"
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
