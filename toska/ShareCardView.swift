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
    @State private var selectedRatio = 0
    @State private var showCopied = false
    @State private var showSharedConfirmation = false
    @State private var sharedPlatform = ""
    
    let styles = ["2am", "numb", "bruise", "ashes", "unsent", "alone", "hollow", "dawn", "paper", "blush", "sage", "frost"]
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
                // MARK: - Header
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
                        // MARK: - Card Preview
                        cardPreview
                            .frame(width: min(cardSize.width * 0.75, 292), height: min(cardSize.height * 0.75, 518))
                            .cornerRadius(2)
                            .shadow(color: cardGlowColor.opacity(0.12), radius: 30, y: 10)
                            .padding(.top, 16)
                        
                        // MARK: - Style Picker
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
                                                .background(
                                                    selectedStyle == index
                                                        ? styleHighlightColor(index).opacity(0.1)
                                                        : Color.clear
                                                )
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
                        
                        // MARK: - Share Platforms
                        HStack(spacing: 0) {
                            platformButton(name: "Stories", icon: "camera.fill", color: Color(hex: "c45c5c").opacity(0.8)) {
                                shareToInstagramStories()
                            }
                            platformButton(name: "TikTok", icon: "play.fill", color: .white.opacity(0.6)) {
                                sharedPlatform = "TikTok"
                                shareImage()
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
                            UIPasteboard.general.string = "\"\(text)\"\n\n— \(handle) on toska"
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
            
            // MARK: - Post-Share Confirmation
            if showSharedConfirmation {
                Color.black.opacity(0.7).ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.3)) {
                            showSharedConfirmation = false
                        }
                    }
                
                VStack(spacing: 14) {
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
            case 0: return Color(hex: "9198a8")    // 2am
            case 1: return Color(hex: "808080")    // numb
            case 2: return Color(hex: "8b7ec8")    // bruise
            case 3: return Color(hex: "c45c5c")    // ashes
            case 4: return Color(hex: "7a97b5")    // unsent
            case 5: return Color(hex: "c49a6c")    // alone
            case 6: return Color(hex: "5a6a5a")    // hollow
            case 7: return Color(hex: "c9a97a")    // dawn
            case 8: return Color(hex: "999999")    // paper
            case 9: return Color(hex: "c47a8a")    // blush
            case 10: return Color(hex: "6ba58e")   // sage
            case 11: return Color(hex: "7a97b5")   // frost
            default: return Color(hex: "9198a8")
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
                
                // Tag — very subtle
                if let tag = tag, selectedRatio != 2 {
                    Text(tag)
                        .font(.system(size: 8, weight: .medium))
                        .tracking(1.5)
                        .foregroundColor(accentColor.opacity(0.3))
                        .padding(.bottom, 12)
                }
                
                // The quote
                Text(text)
                    .font(.custom("Georgia", size: fontSize))
                    .foregroundColor(textColor)
                    .lineSpacing(lineSpacing)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, textPadding)
                
                Spacer()
                
                // Bottom — minimal
                VStack(spacing: 5) {
                    if feltCount > 0 {
                        Text("\(formatCount(feltCount)) felt this")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(accentColor.opacity(0.25))
                    }
                    
                    Rectangle()
                        .fill(accentColor.opacity(0.08))
                        .frame(width: 20, height: 0.5)
                        .padding(.vertical, 2)
                    
                    Text("toska")
                        .font(.custom("Georgia-Italic", size: 9))
                        .foregroundColor(textColor.opacity(0.1))
                }
                .padding(.bottom, selectedRatio == 2 ? 10 : 18)
            }
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
            case 0: // 2am — faint cold glow at bottom
                VStack {
                    Spacer()
                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [Color(hex: "9198a8").opacity(0.04), Color.clear],
                                center: .center,
                                startRadius: 0,
                                endRadius: 180
                            )
                        )
                        .frame(width: 360, height: 200)
                        .offset(y: 60)
                }
                
            case 2: // bruise — purple haze top
                VStack {
                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [Color(hex: "8b7ec8").opacity(0.04), Color.clear],
                                center: .center,
                                startRadius: 0,
                                endRadius: 160
                            )
                        )
                        .frame(width: 300, height: 200)
                        .offset(y: -30)
                    Spacer()
                }
                
            case 3: // ashes — dying ember glow
                VStack {
                    Spacer()
                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [Color(hex: "c45c5c").opacity(0.03), Color.clear],
                                center: .center,
                                startRadius: 0,
                                endRadius: 140
                            )
                        )
                        .frame(width: 280, height: 180)
                        .offset(y: 40)
                }
                
            case 4: // unsent — cold blue at center
                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [Color(hex: "7a97b5").opacity(0.03), Color.clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 150
                        )
                    )
                    .frame(width: 300, height: 300)
                
            case 5: // alone — dim warm light, like a single lamp
                VStack {
                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [Color(hex: "c49a6c").opacity(0.04), Color.clear],
                                center: .center,
                                startRadius: 0,
                                endRadius: 120
                            )
                        )
                        .frame(width: 240, height: 240)
                        .offset(y: 30)
                    Spacer()
                }
                
            case 7: // dawn — warm light glow
                            VStack {
                                Ellipse()
                                    .fill(RadialGradient(colors: [Color(hex: "c9a97a").opacity(0.08), Color.clear], center: .center, startRadius: 0, endRadius: 160))
                                    .frame(width: 300, height: 250)
                                    .offset(y: -20)
                                Spacer()
                            }
                        case 9: // blush — soft pink center
                            Ellipse()
                                .fill(RadialGradient(colors: [Color(hex: "c47a8a").opacity(0.06), Color.clear], center: .center, startRadius: 0, endRadius: 140))
                                .frame(width: 280, height: 280)
                        case 10: // sage — gentle green bottom
                            VStack {
                                Spacer()
                                Ellipse()
                                    .fill(RadialGradient(colors: [Color(hex: "6ba58e").opacity(0.06), Color.clear], center: .center, startRadius: 0, endRadius: 150))
                                    .frame(width: 300, height: 200)
                                    .offset(y: 50)
                            }
                        case 11: // frost — cold blue top
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
            case 8: return Color(hex: "2a2a2a").opacity(0.7)
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
                    Text(tag)
                        .font(.system(size: 9, weight: .medium))
                        .tracking(1.5)
                        .foregroundColor(accentColor.opacity(0.3))
                        .padding(.bottom, 16)
                }
                
                Text(text)
                    .font(.custom("Georgia", size: renderFontSize))
                    .foregroundColor(textColor)
                    .lineSpacing(lineSpacing + 1)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, selectedRatio == 2 ? 26 : 38)
                
                Spacer()
                
                VStack(spacing: 6) {
                    if feltCount > 0 {
                        Text("\(formatCount(feltCount)) felt this")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(accentColor.opacity(0.25))
                    }
                    
                    Rectangle()
                        .fill(accentColor.opacity(0.08))
                        .frame(width: 24, height: 0.5)
                        .padding(.vertical, 2)
                    
                    Text("toska")
                        .font(.custom("Georgia-Italic", size: 10))
                        .foregroundColor(textColor.opacity(0.1))
                }
                .padding(.bottom, selectedRatio == 2 ? 14 : 24)
            }
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .environment(\.colorScheme, selectedStyle >= 7 ? .light : .dark)
        
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
    
    func shareImage() {
        guard let image = renderCardImage() else { return }
        presentShareSheet(with: [image])
        showPostShareConfirmation()
    }
    
    func shareToInstagramStories() {
        guard let image = renderCardImage() else { return }
        guard let imageData = image.pngData() else { return }
        
        let pasteboardItems: [String: Any] = [
            "com.instagram.sharedSticker.backgroundImage": imageData,
            "com.instagram.sharedSticker.backgroundTopColor": selectedStyle >= 7 ? "#f0f0ec" : "#0a0908",
                        "com.instagram.sharedSticker.backgroundBottomColor": selectedStyle >= 7 ? "#f0f0ec" : "#0a0908"
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
            let tweetText = "\"\(text)\"\n\n— someone on toska"
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
