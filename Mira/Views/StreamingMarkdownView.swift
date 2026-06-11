import SwiftUI

// MARK: - Block model (mirrors HeyClicky's MarkdownBlock)

enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(spans: [MarkdownSpan])
    case codeBlock(language: String, code: String)
    case bulletList(items: [String])
    case blockquote(text: String)
}

enum MarkdownSpan {
    case plain(String)
    case bold(String)
    case italic(String)
    case inlineCode(String)
}

// MARK: - Parser

enum MarkdownParser {
    static func parse(_ raw: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = raw.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]

            // Fenced code block
            if line.hasPrefix("```") {
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                i += 1
                var codeLines: [String] = []
                while i < lines.count && !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 } // consume closing ```
                blocks.append(.codeBlock(language: lang, code: codeLines.joined(separator: "\n")))
                continue
            }

            // ATX heading
            if line.hasPrefix("#") {
                let level = min(line.prefix(while: { $0 == "#" }).count, 4)
                let text = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { blocks.append(.heading(level: level, text: text)) }
                i += 1
                continue
            }

            // Blockquote
            if line.hasPrefix("> ") {
                blocks.append(.blockquote(text: String(line.dropFirst(2))))
                i += 1
                continue
            }

            // Bullet list (gather consecutive items)
            if isBullet(line) {
                var items: [String] = []
                while i < lines.count && (isBullet(lines[i]) || lines[i].isEmpty) {
                    if isBullet(lines[i]) { items.append(bulletText(lines[i])) }
                    else { break }   // stop at blank line
                    i += 1
                }
                if !items.isEmpty { blocks.append(.bulletList(items: items)) }
                continue
            }

            // Blank line
            if line.trimmingCharacters(in: .whitespaces).isEmpty { i += 1; continue }

            // Paragraph (gather consecutive non-structural lines)
            var paraLines: [String] = []
            while i < lines.count {
                let l = lines[i]
                if l.trimmingCharacters(in: .whitespaces).isEmpty { break }
                if l.hasPrefix("#") || l.hasPrefix("```") || l.hasPrefix("> ") || isBullet(l) { break }
                paraLines.append(l)
                i += 1
            }
            if !paraLines.isEmpty {
                let combined = paraLines.joined(separator: " ")
                blocks.append(.paragraph(spans: parseSpans(combined)))
            }
        }

        return blocks
    }

    private static func isBullet(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ")
    }

    private static func bulletText(_ line: String) -> String {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
            return String(line.dropFirst(2))
        }
        return line
    }

    static func parseSpans(_ text: String) -> [MarkdownSpan] {
        var spans: [MarkdownSpan] = []
        var remaining = Substring(text)

        while !remaining.isEmpty {
            // Bold **…**
            if remaining.hasPrefix("**") {
                let inner = remaining.dropFirst(2)
                if let end = inner.range(of: "**") {
                    spans.append(.bold(String(inner[..<end.lowerBound])))
                    remaining = inner[end.upperBound...]
                    continue
                }
            }
            // Inline code `…`
            if remaining.hasPrefix("`") {
                let inner = remaining.dropFirst(1)
                if let end = inner.range(of: "`") {
                    spans.append(.inlineCode(String(inner[..<end.lowerBound])))
                    remaining = inner[end.upperBound...]
                    continue
                }
            }
            // Italic *…*
            if remaining.hasPrefix("*") {
                let inner = remaining.dropFirst(1)
                if let end = inner.range(of: "*") {
                    spans.append(.italic(String(inner[..<end.lowerBound])))
                    remaining = inner[end.upperBound...]
                    continue
                }
            }
            // Advance to next marker
            let markers = ["**", "`", "*"]
            var next = remaining.endIndex
            for m in markers {
                if let r = remaining.range(of: m), r.lowerBound < next { next = r.lowerBound }
            }
            if next == remaining.endIndex {
                spans.append(.plain(String(remaining)))
                break
            }
            if next > remaining.startIndex {
                spans.append(.plain(String(remaining[..<next])))
            }
            remaining = remaining[next...]
        }

        return spans
    }
}

// MARK: - StreamingMarkdownView

struct StreamingMarkdownView: View {
    let text: String
    var fontSize: CGFloat = 13

    private var blocks: [MarkdownBlock] { MarkdownParser.parse(text) }

    private let codeBackground = Color(red: 0.10, green: 0.10, blue: 0.14)
    private let codeBorder     = Color.white.opacity(0.08)
    private let quoteBorder    = DS.Colors.accent.opacity(0.50)
    private let bulletDot      = DS.Colors.accent.opacity(0.60)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {

        case .heading(let level, let text):
            let size: CGFloat = level == 1 ? fontSize + 4 : level == 2 ? fontSize + 2 : fontSize + 1
            Text(text)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(.white.opacity(0.95))

        case .paragraph(let spans):
            spansView(spans)
                .font(.system(size: fontSize))
                .foregroundColor(.white.opacity(0.88))
                .lineSpacing(4)

        case .codeBlock(let language, let code):
            VStack(alignment: .leading, spacing: 0) {
                if !language.isEmpty {
                    Text(language)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.35))
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(size: fontSize - 1, design: .monospaced))
                        .foregroundColor(.white.opacity(0.82))
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                        .padding(.top, language.isEmpty ? 8 : 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(codeBackground)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(codeBorder, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Circle()
                            .fill(bulletDot)
                            .frame(width: 4, height: 4)
                            .padding(.top, 6)
                        Text(item)
                            .font(.system(size: fontSize))
                            .foregroundColor(.white.opacity(0.85))
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .blockquote(let text):
            HStack(spacing: 0) {
                Rectangle()
                    .fill(quoteBorder)
                    .frame(width: 2)
                Text(text)
                    .font(.system(size: fontSize - 1))
                    .foregroundColor(.white.opacity(0.55))
                    .italic()
                    .padding(.leading, 8)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func spansView(_ spans: [MarkdownSpan]) -> Text {
        spans.reduce(Text("")) { result, span in
            switch span {
            case .plain(let s):
                return result + Text(s)
            case .bold(let s):
                return result + Text(s).bold()
            case .italic(let s):
                return result + Text(s).italic()
            case .inlineCode(let s):
                return result + Text(s)
                    .font(.system(size: fontSize - 1, design: .monospaced))
                    .foregroundColor(Color(red: 0.75, green: 0.55, blue: 1.0))
            }
        }
    }
}
