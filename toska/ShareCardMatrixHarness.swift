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

    static let styleNames = ["2am", "dusk", "numb", "bruise", "ashes", "unsent", "alone", "hollow", "dawn", "paper", "blush", "sage", "frost"]
    static let ratioNames = ["story", "square"]

    static func run(outDir: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        var report: [String] = []
        let fontNames = ["serif", "sans", "mono", "hand"]
        let sizeNames = ["S", "M", "L"]
        let alignNames = ["L", "C", "R"]

        // ---- Main truncation matrix: per (text, ratio) contact sheet.
        // Rows = 4 fonts; columns = 3 sizes × 3 alignments. Style fixed to
        // dawn (8, default) — truncation is style-independent.
        for stress in texts {
            for ratio in 0..<ratioNames.count {
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

        // ---- Custom-color legibility: user-picked grounds across the
        // brightness range — ink/accents must adapt (dark → light text,
        // light → dark text) and the footer must stay intact.
        let customs: [(String, Color)] = [
            ("nearblack", Color(red: 0.04, green: 0.04, blue: 0.05)),
            ("hotpink", Color(red: 0.91, green: 0.12, blue: 0.55)),
            ("midblue", Color(red: 0.23, green: 0.35, blue: 0.60)),
            ("butter", Color(red: 0.96, green: 0.91, blue: 0.78)),
            ("white", Color(red: 0.98, green: 0.98, blue: 0.98)),
        ]
        var customCells: [(row: Int, col: Int, image: UIImage, label: String)] = []
        for (i, (name, color)) in customs.enumerated() {
            let view = ShareCardView(
                text: styleText.text, handle: "harness", feltCount: 2437,
                tag: styleText.tag, matrixStyle: ShareCardView.customStyle,
                font: 0, size: 1, alignment: 1, ratio: 1, customColor: color)
            if let img = view.renderCardImage(scale: 1.0) {
                customCells.append((0, i, img, name))
            }
        }
        writeSheet(cells: customCells, rows: 1, cols: customs.count,
                   path: "\(outDir)/custom_colors.png")

        // ---- Full-scale singles for the riskiest combos (eyeball at 3x).
        let singles: [(Int, Int, Int, Int, Int, Int)] = [
            // (textKey-index, style, font, size, align, ratio)
            (1, 1, 0, 2, 1, 1),   // max post, dusk, serif, LARGE, center, SQUARE
            (7, 8, 2, 2, 1, 1),   // 2000-char letter, mono, LARGE, SQUARE — worst case
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

        // ---- Fragment selection driving the card.
        let fragmentView = ShareCardView(
            text: texts[1].text, handle: "harness", feltCount: 999,
            tag: texts[1].tag, matrixStyle: 1, font: 0, size: 1,
            alignment: 1, ratio: 0, fragment: [0, 5])
        report.append("fragment cardText: \(fragmentView.cardText.prefix(160))")
        if let img = fragmentView.renderCardImage(scale: 2.0) {
            try? img.pngData()?.write(to: URL(fileURLWithPath: "\(outDir)/fragment_maxpost.png"))
        }

        try? report.joined(separator: "\n")
            .write(toFile: "\(outDir)/fitted_report.tsv", atomically: true, encoding: .utf8)
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
