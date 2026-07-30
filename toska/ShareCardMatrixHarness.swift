// DEBUG-only render harness: sweeps the share card's full composer matrix
// (ratio × font × size × alignment × stress texts) through the REAL export
// path (renderCardImage) and writes contact-sheet PNGs for visual truncation
// review. Never runs in production: compiled out of Release, and even in
// Debug it only fires when the SHARECARD_MATRIX_OUT env var is set (via
// `simctl launch` with SIMCTL_CHILD_SHARECARD_MATRIX_OUT).
#if DEBUG
import SwiftUI
import UIKit

@MainActor
enum ShareCardMatrixHarness {
    static func runIfRequested() {
        guard let outDir = ProcessInfo.processInfo.environment["SHARECARD_MATRIX_OUT"],
              !outDir.isEmpty else { return }
        // Let the app finish launching before monopolizing the main actor.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            run(outDir: outDir)
            print("SHARECARD_MATRIX_DONE")
            exit(0)
        }
    }

    struct StressText {
        let key: String
        let text: String
        let tag: String?
    }

    static let texts: [StressText] = [
        .init(key: "one-char", text: "k", tag: "numb"),
        // 500 chars — the real post maximum.
        .init(key: "max-post",
              text: String(repeating: "i keep rereading the last thing you sent me like it's going to change. it never changes. ", count: 5) + "and still i wait for a name that never lights up my phone anymore.",
              tag: "waiting for someone who moved on entirely"),
        // Paragraphs + blank lines — newlines survive into post text.
        .init(key: "paragraphs",
              text: "you left on a tuesday.\n\nnothing about tuesdays has been ordinary since.\n\ni still make two cups of coffee.\ni still say goodnight.\n\nthe apartment answers in your voice sometimes, when the radiator kicks on and the floor creaks where you used to stand.",
              tag: "grief"),
        // Single unbroken token, wide glyphs — worst case for wrapping.
        .init(key: "unbroken-token", text: String(repeating: "W", count: 300), tag: nil),
        // Emoji-heavy including ZWJ families and modifiers.
        .init(key: "emoji-heavy",
              text: "💔💔💔 you said forever 👨‍👩‍👧‍👦 and then you left 🥀🥀 " + String(repeating: "😭💔🥀✨🌙 ", count: 12) + "i'm still here 🫀",
              tag: "still hurting"),
        // CJK (no spaces) + Cyrillic mix.
        .init(key: "non-latin",
              text: "彼がいなくなってから、部屋の静けさが違う音を立てるようになった。誰もいない台所でお湯を沸かす。" + "Я всё ещё жду сообщения, которое никогда не придёт. Это тоска." + "夜中に目が覚めて、隣の冷たさに慣れない。慣れたくない。",
              tag: "тоска"),
        // Arabic — RTL script.
        .init(key: "rtl-arabic",
              text: "ما زلت أنتظر رسالة لن تصل أبداً. كل ليلة أقرأ آخر ما كتبتَه لي وكأن القراءة ستغير النهاية. البيت هادئ الآن لكنه ليس سلاماً، إنه فراغ يشبه صوتك حين يغيب.",
              tag: nil),
        // 2000 chars — the letter maximum. Letters can't reach the share card
        // today (entry points block isLetter), but the engine must survive it.
        .init(key: "letter-2000",
              text: String(repeating: "i wrote you this letter knowing you will never read it. that is the only way i can be honest anymore. ", count: 19) + "goodbye.",
              tag: nil),
    ]

    static func run(outDir: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        var report: [String] = []
        let fontNames = ["serif", "sans", "mono", "hand"]
        let sizeNames = ["S", "M", "L"]
        let alignNames = ["L", "C", "R"]
        let ratioNames = ["story", "square", "wide"]

        // ---- Main truncation matrix: per (text, ratio) contact sheet.
        // Rows = 4 fonts; columns = 3 sizes × 3 alignments. Style fixed to
        // dawn (8, default) — truncation is style-independent.
        for stress in texts {
            for ratio in 0..<3 {
                var cells: [(row: Int, col: Int, image: UIImage, label: String)] = []
                for font in 0..<4 {
                    for size in 0..<3 {
                        for align in 0..<3 {
                            let view = ShareCardView(
                                text: stress.text, handle: "harness", feltCount: 2437,
                                tag: stress.tag, matrixStyle: 8, font: font,
                                size: size, alignment: align, ratio: ratio)
                            let fitted = view.fittedFontSize
                            guard let img = view.renderCardImage(scale: 1.0) else {
                                report.append("RENDER-FAIL \(stress.key) ratio=\(ratioNames[ratio]) font=\(fontNames[font]) size=\(sizeNames[size]) align=\(alignNames[align])")
                                continue
                            }
                            let label = "\(fontNames[font]) \(sizeNames[size])\(alignNames[align]) f=\(String(format: "%.1f", fitted))"
                            cells.append((font, size * 3 + align, img, label))
                            report.append("\(stress.key)\tratio=\(ratioNames[ratio])\tfont=\(fontNames[font])\tsize=\(sizeNames[size])\talign=\(alignNames[align])\tfitted=\(String(format: "%.2f", fitted))\tfloor=\(fitted <= 5.01 ? "YES" : "no")")
                        }
                    }
                }
                writeSheet(cells: cells, rows: 4, cols: 9,
                           path: "\(outDir)/matrix_\(stress.key)_\(ratioNames[ratio]).png")
            }
        }

        // ---- Style legibility sheet: all 13 moods, medium text, story ratio.
        let styleText = texts[2]
        var styleCells: [(row: Int, col: Int, image: UIImage, label: String)] = []
        let styleNames = ["2am", "dusk", "numb", "bruise", "ashes", "unsent", "alone", "hollow", "dawn", "paper", "blush", "sage", "frost"]
        for style in 0..<13 {
            let view = ShareCardView(
                text: styleText.text, handle: "harness", feltCount: 23400,
                tag: styleText.tag, matrixStyle: style, font: 0,
                size: 1, alignment: 1, ratio: 0)
            if let img = view.renderCardImage(scale: 1.0) {
                styleCells.append((style / 7, style % 7, img, styleNames[style]))
            }
        }
        writeSheet(cells: styleCells, rows: 2, cols: 7, path: "\(outDir)/styles_all13.png")

        // ---- Full-scale singles for the riskiest combos (eyeball at 3x).
        let singles: [(Int, Int, Int, Int, Int, Int)] = [
            // (textKey-index, style, font, size, align, ratio)
            (1, 1, 0, 2, 1, 2),   // max post, dusk, serif, LARGE, center, WIDE — least room
            (7, 8, 2, 2, 1, 2),   // 2000-char letter, mono, LARGE, WIDE — worst case
            (3, 0, 3, 2, 0, 1),   // unbroken token, 2am, hand, LARGE, left, square
            (4, 2, 0, 2, 1, 0),   // emoji, numb, serif, LARGE, story
            (6, 7, 0, 1, 2, 0),   // RTL, hollow, serif, M, right-aligned, story
        ]
        for (ti, style, font, size, align, ratio) in singles {
            let stress = texts[ti]
            let view = ShareCardView(
                text: stress.text, handle: "harness", feltCount: 999,
                tag: stress.tag, matrixStyle: style, font: font,
                size: size, alignment: align, ratio: ratio)
            if let img = view.renderCardImage(scale: 3.0),
               let data = img.pngData() {
                try? data.write(to: URL(fileURLWithPath: "\(outDir)/single_\(stress.key)_\(styleNames[style])_\(ratioNames[ratio]).png"))
            }
        }

        try? report.joined(separator: "\n")
            .write(toFile: "\(outDir)/fitted_report.tsv", atomically: true, encoding: .utf8)

        // ---- Layout probe: measure cardBody's IDEAL height (width fixed,
        // height unconstrained) for the wide-footer displacement bug, and
        // diff variants to identify the oversized element.
        var probe: [String] = []
        func idealHeight(_ v: some View) -> CGFloat {
            let r = ImageRenderer(content: v.frame(width: 390))
            r.scale = 1.0
            return r.uiImage?.size.height ?? -1
        }
        let base = ShareCardView(text: texts[1].text, handle: "h", feltCount: 999,
                                 tag: texts[1].tag, matrixStyle: 1, font: 0,
                                 size: 2, alignment: 1, ratio: 2)
        probe.append("wide serif L: fitted=\(base.fittedFontSize) quoteFrame=\(base.fittedQuoteHeight) quoteMax=\(base.quoteMaxHeight)")
        probe.append("cardBody ideal height (wide, felt on): \(idealHeight(base.cardBody))")
        let noFelt = ShareCardView(text: texts[1].text, handle: "h", feltCount: 0,
                                   tag: texts[1].tag, matrixStyle: 1, font: 0,
                                   size: 2, alignment: 1, ratio: 2)
        probe.append("cardBody ideal height (wide, felt off): \(idealHeight(noFelt.cardBody))")
        let story = ShareCardView(text: texts[1].text, handle: "h", feltCount: 999,
                                  tag: texts[1].tag, matrixStyle: 1, font: 0,
                                  size: 2, alignment: 1, ratio: 0)
        probe.append("cardBody ideal height (story, felt on): \(idealHeight(story.cardBody)) (card 690)")
        // Element-level: footer VStack alone at unconstrained height.
        probe.append("footer-only ideal (wide): \(idealHeight(base.footerProbe))")
        probe.append("quotemark-only ideal (wide): \(idealHeight(base.quoteMarkProbe))")
        try? probe.joined(separator: "\n")
            .write(toFile: "\(outDir)/layout_probe.txt", atomically: true, encoding: .utf8)

        // ---- Tinted diagnostics: replica of cardBody with per-element
        // backgrounds, rendered with and without cardDecorations, to see
        // exactly which element lands where on the wide card.
        func diagBody(_ v: ShareCardView, text: String) -> some View {
            VStack(spacing: 0) {
                Spacer(minLength: 0).frame(maxHeight: .infinity)
                    .background(Color.green.opacity(0.35))
                v.quoteMarkProbe.background(Color.yellow.opacity(0.45))
                Text(text)
                    .font(v.quoteFont(size: v.fittedFontSize))
                    .foregroundColor(v.textColor)
                    .lineSpacing(v.lineSpacing)
                    .multilineTextAlignment(v.textAlignment)
                    .minimumScaleFactor(0.15)
                    .padding(.horizontal, v.textPadding)
                    .frame(height: v.fittedQuoteHeight)
                    .background(Color.red.opacity(0.35))
                Spacer(minLength: 0).frame(maxHeight: .infinity)
                    .background(Color.blue.opacity(0.35))
                v.footerProbe.background(Color.orange.opacity(0.55))
            }
        }
        let diagView = ShareCardView(text: texts[1].text, handle: "h", feltCount: 999,
                                     tag: texts[1].tag, matrixStyle: 1, font: 0,
                                     size: 2, alignment: 1, ratio: 2)
        let withDeco = ZStack {
            diagView.cardBackground
            diagView.cardDecorations
            diagBody(diagView, text: texts[1].text)
        }
        .frame(width: diagView.cardSize.width, height: diagView.cardSize.height)
        .environment(\.colorScheme, .dark)
        let withoutDeco = ZStack {
            diagView.cardBackground
            diagBody(diagView, text: texts[1].text)
        }
        .frame(width: diagView.cardSize.width, height: diagView.cardSize.height)
        .environment(\.colorScheme, .dark)
        let realNoDiag = diagView.renderCardImage(scale: 2.0)
        for (name, view) in [("diag_wide_with_deco", AnyView(withDeco)),
                             ("diag_wide_no_deco", AnyView(withoutDeco))] {
            let r = ImageRenderer(content: view)
            r.scale = 2.0
            if let d = r.uiImage?.pngData() {
                try? d.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
            }
        }
        if let d = realNoDiag?.pngData() {
            try? d.write(to: URL(fileURLWithPath: "\(outDir)/diag_wide_real.png"))
        }
    }

    /// Composites cell images into a labeled grid sheet PNG.
    static func writeSheet(cells: [(row: Int, col: Int, image: UIImage, label: String)],
                           rows: Int, cols: Int, path: String) {
        guard let first = cells.first?.image else { return }
        let thumbW = first.size.width * 0.55
        let thumbH = first.size.height * 0.55
        let labelH: CGFloat = 16
        let gap: CGFloat = 6
        let sheetW = CGFloat(cols) * (thumbW + gap) + gap
        let sheetH = CGFloat(rows) * (thumbH + labelH + gap) + gap
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: sheetW, height: sheetH))
        let sheet = renderer.image { ctx in
            UIColor(white: 0.92, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: UIColor.black,
            ]
            for cell in cells {
                let x = gap + CGFloat(cell.col) * (thumbW + gap)
                let y = gap + CGFloat(cell.row) * (thumbH + labelH + gap)
                cell.image.draw(in: CGRect(x: x, y: y, width: thumbW, height: thumbH))
                (cell.label as NSString).draw(at: CGPoint(x: x, y: y + thumbH + 2), withAttributes: attrs)
            }
        }
        try? sheet.pngData()?.write(to: URL(fileURLWithPath: path))
    }
}
#endif
