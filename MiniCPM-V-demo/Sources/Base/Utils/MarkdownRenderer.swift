//
//  MarkdownRenderer.swift
//  MiniCPM-V-demo
//
//  Lightweight Markdown -> NSAttributedString renderer for streaming AI
//  responses.  Mirrors the feature set of the HarmonyOS MarkdownParser.ets
//  and Android Markwon-core so all three platforms render identically.
//
//  Supported block-level syntax:
//    # .. ######   ATX headings
//    ```lang        fenced code blocks
//    - / * / +      unordered list items
//    1. / 2.        ordered list items
//    >              blockquotes
//    blank line     paragraph separator
//
//  Supported inline syntax (within paragraphs / lists / headings):
//    **bold**
//    *italic*  /  _italic_
//    `inline code`
//    ~~strikethrough~~
//    [text](url)    (rendered as styled text; UILabel cannot make them tappable)
//
//  Streaming-friendly: re-parse the full accumulated string on every token.
//  Partial / unclosed markers render as literal text until they complete,
//  matching Markwon behavior on Android.
//

import UIKit

/// 块种类（供增量渲染精确计算块间分隔符）。
fileprivate enum MarkdownBlockKind {
    case paragraph, heading, listItem, codeBlock, blockquote, horizontalRule, table
}

/// `render` 的完整结果：属性串 + 首/末块的种类。
fileprivate struct MarkdownRenderResult {
    let attributed: NSAttributedString
    let firstKind: MarkdownBlockKind?
    let lastKind: MarkdownBlockKind?
}

enum MarkdownRenderer {

    // MARK: - Public API

    /// Render Markdown text into an NSAttributedString using the given base
    /// attributes (font, color, paragraph style).  The base font size drives
    /// heading scale and code styling.
    static func render(
        _ markdown: String,
        baseAttributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        renderDetailed(markdown, baseAttributes: baseAttributes).attributed
    }

    /// `render` 的增量版：除属性串外，还回传首/末块的种类，供
    /// `StreamingMarkdownRenderer` 精确复原块间分隔符。
    fileprivate static func renderDetailed(
        _ markdown: String,
        baseAttributes: [NSAttributedString.Key: Any]
    ) -> MarkdownRenderResult {

        let baseFont = baseAttributes[.font] as? UIFont
            ?? UIFont.systemFont(ofSize: 16)
        let baseColor = baseAttributes[.foregroundColor] as? UIColor ?? .label
        let result = NSMutableAttributedString()
        let blocks = parseBlocks(markdown)

        for (idx, block) in blocks.enumerated() {
            switch block.type {
            case .heading:
                let fontSize = headingFontSize(level: block.level, base: baseFont.pointSize)
                let font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
                let attrs = mergedAttributes(base: baseAttributes, overrides: [.font: font])
                let rendered = renderInlineSpans(block.spans, baseAttributes: attrs, baseFont: font, baseColor: baseColor)
                result.append(rendered)

            case .codeBlock:
                let codeFont = UIFont(name: "Menlo", size: baseFont.pointSize - 2)
                    ?? UIFont.monospacedSystemFont(ofSize: baseFont.pointSize - 2, weight: .regular)
                let codePara = NSMutableParagraphStyle()
                codePara.lineSpacing = 2
                codePara.lineBreakMode = .byWordWrapping
            let codeAttrs: [NSAttributedString.Key: Any] = [
                .font: codeFont,
                .foregroundColor: UIColor.mb_color(with: "#1F2429") ?? .label,
                .backgroundColor: UIColor.mb_color(with: "#F2F5F7") ?? .secondarySystemBackground,
                .paragraphStyle: codePara
            ]
                result.append(NSAttributedString(string: block.raw, attributes: codeAttrs))

            case .listItem:
                let bullet: String
                if block.level == 0 {
                    bullet = "  •  "
                } else {
                    bullet = "  \(block.level).  "
                }
                let bulletAttrs = mergedAttributes(base: baseAttributes, overrides: [
                    .foregroundColor: baseColor
                ])
                result.append(NSAttributedString(string: bullet, attributes: bulletAttrs))
                let rendered = renderInlineSpans(block.spans, baseAttributes: baseAttributes, baseFont: baseFont, baseColor: baseColor)
                result.append(rendered)

            case .blockquote:
                let quoteColor = UIColor.gray
                let quoteFont = UIFont.italicSystemFont(ofSize: baseFont.pointSize)
                let quoteAttrs = mergedAttributes(base: baseAttributes, overrides: [
                    .foregroundColor: quoteColor,
                    .font: quoteFont
                ])
                let rendered = renderInlineSpans(block.spans, baseAttributes: quoteAttrs, baseFont: quoteFont, baseColor: quoteColor)
                let bar = NSAttributedString(string: "  ▎ ", attributes: quoteAttrs)
                result.append(bar)
                result.append(rendered)

            case .horizontalRule:
                let rulePara = NSMutableParagraphStyle()
                rulePara.lineBreakMode = .byClipping
                rulePara.maximumLineHeight = 22
                rulePara.minimumLineHeight = 22
                let ruleAttrs: [NSAttributedString.Key: Any] = [
                    .foregroundColor: UIColor.separator,
                    .font: baseFont,
                    .paragraphStyle: rulePara
                ]
                let ruleStr = String(repeating: "─", count: 80)
                result.append(NSAttributedString(string: ruleStr, attributes: ruleAttrs))

            case .table:
                let tableFont = UIFont(name: "Menlo", size: baseFont.pointSize - 2)
                    ?? UIFont.monospacedSystemFont(ofSize: baseFont.pointSize - 2, weight: .regular)
                let tablePara = NSMutableParagraphStyle()
                tablePara.lineSpacing = 2
                tablePara.lineBreakMode = .byWordWrapping
                let tableAttrs: [NSAttributedString.Key: Any] = [
                    .font: tableFont,
                    .foregroundColor: baseColor,
                    .paragraphStyle: tablePara
                ]
                result.append(NSAttributedString(string: block.raw, attributes: tableAttrs))

            case .paragraph:
                let rendered = renderInlineSpans(block.spans, baseAttributes: baseAttributes, baseFont: baseFont, baseColor: baseColor)
                result.append(rendered)
            }

            if idx < blocks.count - 1 {
                let sep = separator(after: kind(of: block), before: kind(of: blocks[idx + 1]))
                result.append(NSAttributedString(string: sep, attributes: baseAttributes))
            }
        }

        return MarkdownRenderResult(
            attributed: result,
            firstKind: blocks.first.map { kind(of: $0) },
            lastKind: blocks.last.map { kind(of: $0) })
    }

    /// 块间分隔符：`render` 的循环与增量拼接共用同一份规则，保证增量拼接的结果
    /// 与一次性全量渲染逐字一致。
    fileprivate static func separator(after: MarkdownBlockKind, before: MarkdownBlockKind) -> String {
        if after == .listItem && before == .listItem { return "\n" }
        if after == .heading { return "\n" }
        return "\n\n"
    }

    private static func kind(of block: Block) -> MarkdownBlockKind {
        switch block.type {
        case .paragraph:      return .paragraph
        case .heading:        return .heading
        case .listItem:       return .listItem
        case .codeBlock:      return .codeBlock
        case .blockquote:     return .blockquote
        case .horizontalRule: return .horizontalRule
        case .table:          return .table
        }
    }

    // MARK: - Block parsing

    private enum BlockType {
        case paragraph
        case heading
        case listItem
        case codeBlock
        case blockquote
        case horizontalRule
        case table
    }

    private struct Block {
        let type: BlockType
        let level: Int       // heading 1-6; ordered list index; 0 for unordered/others
        let language: String // code block language hint
        let spans: [InlineSpan]
        let raw: String      // code block raw content
    }

    private static func parseBlocks(_ text: String) -> [Block] {
        var blocks = [Block]()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).replacingOccurrences(of: "\r", with: "") }
        var i = 0

        while i < lines.count {
            let line = lines[i]

            // Fenced code block
            if line.hasPrefix("```") {
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines = [String]()
                i += 1
                while i < lines.count && !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 } // skip closing ```
                blocks.append(Block(
                    type: .codeBlock, level: 0, language: lang,
                    spans: [], raw: codeLines.joined(separator: "\n")))
                continue
            }

            // Heading
            if let match = line.range(of: #"^(#{1,6})\s+(.*)$"#, options: .regularExpression) {
                let fullMatch = String(line[match])
                let hashEnd = fullMatch.firstIndex(of: " ")!
                let level = fullMatch.distance(from: fullMatch.startIndex, to: hashEnd)
                let content = String(fullMatch[fullMatch.index(after: hashEnd)...])
                    .trimmingCharacters(in: .whitespaces)
                blocks.append(Block(
                    type: .heading, level: level, language: "",
                    spans: parseInline(content), raw: content))
                i += 1
                continue
            }

            // Horizontal rule (---, ***, ___)
            if isHorizontalRule(line) {
                blocks.append(Block(
                    type: .horizontalRule, level: 0, language: "",
                    spans: [], raw: ""))
                i += 1
                continue
            }

            // Blockquote
            if line.hasPrefix("> ") || line == ">" {
                let content = line.hasPrefix("> ") ? String(line.dropFirst(2)) : ""
                blocks.append(Block(
                    type: .blockquote, level: 0, language: "",
                    spans: parseInline(content), raw: content))
                i += 1
                continue
            }

            // Table: lines starting with | (collect consecutive table rows)
            if line.hasPrefix("|") && line.hasSuffix("|") {
                var tableLines = [line]
                i += 1
                while i < lines.count {
                    let tl = lines[i]
                    if tl.hasPrefix("|") {
                        tableLines.append(tl)
                        i += 1
                    } else {
                        break
                    }
                }
                let tableRaw = tableLines.joined(separator: "\n")
                blocks.append(Block(
                    type: .table, level: 0, language: "",
                    spans: [], raw: tableRaw))
                continue
            }

            // Unordered list item (- * + and en-dash – em-dash —)
            if let _ = line.range(of: #"^\s*[-*+–—]\s+(.*)$"#, options: .regularExpression) {
                let content = extractListContent(line, pattern: #"^\s*[-*+–—]\s+"#)
                blocks.append(Block(
                    type: .listItem, level: 0, language: "",
                    spans: parseInline(content), raw: content))
                i += 1
                continue
            }

            // Ordered list item
            if let _ = line.range(of: #"^\s*(\d+)\.\s+(.*)$"#, options: .regularExpression) {
                let (num, content) = extractOrderedListContent(line)
                blocks.append(Block(
                    type: .listItem, level: num, language: "",
                    spans: parseInline(content), raw: content))
                i += 1
                continue
            }

            // Blank line
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1
                continue
            }

            // Paragraph: gather contiguous non-special lines
            var paraLines = [line]
            i += 1
            while i < lines.count {
                let peek = lines[i]
                if peek.trimmingCharacters(in: .whitespaces).isEmpty { break }
                if peek.hasPrefix("```") { break }
                if peek.range(of: #"^#{1,6}\s+"#, options: .regularExpression) != nil { break }
                if peek.range(of: #"^\s*[-*+–—]\s+"#, options: .regularExpression) != nil { break }
                if peek.range(of: #"^\s*\d+\.\s+"#, options: .regularExpression) != nil { break }
                if peek.hasPrefix("> ") || peek == ">" { break }
                if peek.hasPrefix("|") && peek.hasSuffix("|") { break }
                if isHorizontalRule(peek) { break }
                paraLines.append(peek)
                i += 1
            }
            let paragraph = paraLines.joined(separator: "\n")
            blocks.append(Block(
                type: .paragraph, level: 0, language: "",
                spans: parseInline(paragraph), raw: paragraph))
        }

        return blocks
    }

    private static func extractListContent(_ line: String, pattern: String) -> String {
        guard let range = line.range(of: pattern, options: .regularExpression) else {
            return line
        }
        return String(line[range.upperBound...])
    }

    private static func extractOrderedListContent(_ line: String) -> (Int, String) {
        guard let dotRange = line.range(of: #"^\s*(\d+)\.\s+"#, options: .regularExpression) else {
            return (1, line)
        }
        let prefix = String(line[line.startIndex..<dotRange.upperBound])
        let digits = prefix.filter { $0.isNumber }
        let num = Int(digits) ?? 1
        let content = String(line[dotRange.upperBound...])
        return (num, content)
    }

    // MARK: - Inline parsing

    private enum InlineType {
        case text
        case bold
        case italic
        case boldItalic
        case code
        case strikethrough
        case link
    }

    private struct InlineSpan {
        let type: InlineType
        let text: String
        let url: String // only for .link
    }

    private static func parseInline(_ text: String) -> [InlineSpan] {
        var spans = [InlineSpan]()
        var buf = ""
        var i = text.startIndex

        func flushBuf() {
            if !buf.isEmpty {
                spans.append(InlineSpan(type: .text, text: buf, url: ""))
                buf = ""
            }
        }

        func remaining(_ from: String.Index) -> Int {
            text.distance(from: from, to: text.endIndex)
        }

        while i < text.endIndex {
            let ch = text[i]

            // ***bold italic*** (three asterisks)
            if ch == "*", remaining(i) >= 6 {
                let i1 = text.index(after: i)
                let i2 = text.index(after: i1)
                if text[i1] == "*" && text[i2] == "*" {
                    let searchStart = text.index(i, offsetBy: 3)
                    if let closeRange = text.range(of: "***", range: searchStart..<text.endIndex) {
                        let inner = String(text[searchStart..<closeRange.lowerBound])
                        if !inner.isEmpty && !inner.contains("\n") {
                            flushBuf()
                            spans.append(InlineSpan(type: .boldItalic, text: inner, url: ""))
                            i = closeRange.upperBound
                            continue
                        }
                    }
                }
            }

            // **bold**
            if ch == "*", remaining(i) >= 4 {
                let nextIdx = text.index(after: i)
                if text[nextIdx] == "*" {
                    let searchStart = text.index(i, offsetBy: 2)
                    if let closeRange = text.range(of: "**", range: searchStart..<text.endIndex) {
                        let inner = String(text[searchStart..<closeRange.lowerBound])
                        if !inner.isEmpty && !inner.contains("\n") {
                            flushBuf()
                            spans.append(InlineSpan(type: .bold, text: inner, url: ""))
                            i = closeRange.upperBound
                            continue
                        }
                    }
                }
            }

            // ~~strikethrough~~
            if ch == "~", remaining(i) >= 4 {
                let nextIdx = text.index(after: i)
                if text[nextIdx] == "~" {
                    let searchStart = text.index(i, offsetBy: 2)
                    if let closeRange = text.range(of: "~~", range: searchStart..<text.endIndex) {
                        let inner = String(text[searchStart..<closeRange.lowerBound])
                        if !inner.isEmpty && !inner.contains("\n") {
                            flushBuf()
                            spans.append(InlineSpan(type: .strikethrough, text: inner, url: ""))
                            i = closeRange.upperBound
                            continue
                        }
                    }
                }
            }

            // *italic* or _italic_ (single marker, NOT followed by same char)
            if (ch == "*" || ch == "_"), remaining(i) >= 3 {
                let nextIdx = text.index(after: i)
                let next = text[nextIdx]
                if next != ch && next != " " && next != "\n" {
                    if let closeIdx = text[nextIdx...].firstIndex(of: ch) {
                        // Ensure closing marker is not part of a `**`
                        let afterClose = text.index(after: closeIdx)
                        let closingIsDouble = afterClose < text.endIndex && text[afterClose] == ch
                        if !closingIsDouble {
                            let inner = String(text[nextIdx..<closeIdx])
                            if !inner.isEmpty && !inner.contains("\n") {
                                flushBuf()
                                spans.append(InlineSpan(type: .italic, text: inner, url: ""))
                                i = afterClose
                                continue
                            }
                        }
                    }
                }
            }

            // `inline code`
            if ch == "`" {
                let nextIdx = text.index(after: i)
                if nextIdx < text.endIndex,
                   let closeIdx = text[nextIdx...].firstIndex(of: "`") {
                    let inner = String(text[nextIdx..<closeIdx])
                    if !inner.isEmpty {
                        flushBuf()
                        spans.append(InlineSpan(type: .code, text: inner, url: ""))
                        i = text.index(after: closeIdx)
                        continue
                    }
                }
            }

            // ![text](url) — image syntax (render as link with label)
            if ch == "!", remaining(i) >= 5 {
                let nextIdx = text.index(after: i)
                if text[nextIdx] == "[" {
                    if let result = parseLinkAt(text, from: nextIdx) {
                        flushBuf()
                        spans.append(InlineSpan(type: .link, text: "[\(result.text)]", url: result.url))
                        i = result.end
                        continue
                    }
                }
            }

            // [text](url)
            if ch == "[" {
                if let result = parseLinkAt(text, from: i) {
                    flushBuf()
                    spans.append(InlineSpan(type: .link, text: result.text, url: result.url))
                    i = result.end
                    continue
                }
            }

            buf.append(ch)
            i = text.index(after: i)
        }

        flushBuf()
        return spans
    }

    private struct LinkParseResult {
        let text: String
        let url: String
        let end: String.Index
    }

    private static func parseLinkAt(_ text: String, from start: String.Index) -> LinkParseResult? {
        guard text[start] == "[" else { return nil }
        let afterBracket = text.index(after: start)
        guard let closeBracket = text[afterBracket...].firstIndex(of: "]") else { return nil }
        let linkText = String(text[afterBracket..<closeBracket])

        let parenStart = text.index(after: closeBracket)
        guard parenStart < text.endIndex, text[parenStart] == "(" else { return nil }
        let afterParen = text.index(after: parenStart)
        guard let closeParen = text[afterParen...].firstIndex(of: ")") else { return nil }
        let url = String(text[afterParen..<closeParen])

        return LinkParseResult(text: linkText, url: url, end: text.index(after: closeParen))
    }

    // MARK: - Inline span -> NSAttributedString

    private static func renderInlineSpans(
        _ spans: [InlineSpan],
        baseAttributes: [NSAttributedString.Key: Any],
        baseFont: UIFont,
        baseColor: UIColor
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()

        for span in spans {
            switch span.type {
            case .text:
                result.append(NSAttributedString(string: span.text, attributes: baseAttributes))

            case .bold:
                let boldFont = UIFont.systemFont(ofSize: baseFont.pointSize, weight: .bold)
                let attrs = mergedAttributes(base: baseAttributes, overrides: [.font: boldFont])
                result.append(NSAttributedString(string: span.text, attributes: attrs))

            case .italic:
                let italicFont = UIFont.italicSystemFont(ofSize: baseFont.pointSize)
                let attrs = mergedAttributes(base: baseAttributes, overrides: [.font: italicFont])
                result.append(NSAttributedString(string: span.text, attributes: attrs))

            case .boldItalic:
                let descriptor = UIFont.systemFont(ofSize: baseFont.pointSize, weight: .bold)
                    .fontDescriptor.withSymbolicTraits([.traitBold, .traitItalic])
                let biFont = descriptor.map { UIFont(descriptor: $0, size: baseFont.pointSize) }
                    ?? UIFont.systemFont(ofSize: baseFont.pointSize, weight: .bold)
                let attrs = mergedAttributes(base: baseAttributes, overrides: [.font: biFont])
                result.append(NSAttributedString(string: span.text, attributes: attrs))

            case .code:
                let codeFont = UIFont(name: "Menlo", size: baseFont.pointSize - 1)
                    ?? UIFont.monospacedSystemFont(ofSize: baseFont.pointSize - 1, weight: .regular)
            let attrs = mergedAttributes(base: baseAttributes, overrides: [
                .font: codeFont,
                .foregroundColor: UIColor.mb_color(with: "#C7264D") ?? .label,
                .backgroundColor: UIColor.mb_color(with: "#F7EDF0") ?? .tertiarySystemBackground
            ])
                result.append(NSAttributedString(string: span.text, attributes: attrs))

            case .strikethrough:
                let attrs = mergedAttributes(base: baseAttributes, overrides: [
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue
                ])
                result.append(NSAttributedString(string: span.text, attributes: attrs))

            case .link:
                let linkColor = UIColor.systemBlue
                let attrs = mergedAttributes(base: baseAttributes, overrides: [
                    .foregroundColor: linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ])
                result.append(NSAttributedString(string: span.text, attributes: attrs))
            }
        }

        return result
    }

    // MARK: - Helpers

    private static func isHorizontalRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.count < 3 { return false }
        let stripped = trimmed.filter { $0 != " " }
        let chars = Set(stripped)
        return chars.count == 1 && (chars.contains("-") || chars.contains("*") || chars.contains("_"))
            && stripped.count >= 3
    }

    private static func headingFontSize(level: Int, base: CGFloat) -> CGFloat {
        switch level {
        case 1: return base + 8
        case 2: return base + 5
        case 3: return base + 3
        case 4: return base + 1
        default: return base
        }
    }

    private static func mergedAttributes(
        base: [NSAttributedString.Key: Any],
        overrides: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        var merged = base
        for (key, value) in overrides {
            merged[key] = value
        }
        return merged
    }
}

// MARK: - 流式增量渲染

/// 流式 Markdown 增量渲染缓存。
///
/// 为什么需要：`MarkdownRenderer.render` 每次都拿**全量文本**重做块解析 + 行内解析，
/// 流式路径上每个 flush（约 20fps）调一次就是 O(N²) 主线程开销 —— 这正是此前
/// 流式期间刻意跳过 markdown 的原因。这里把「已经写完、不会再变的块」冻结成
/// NSAttributedString 缓存，每帧只解析「新定型的块」+「当前未定型的尾块」，
/// 把每帧成本从 O(全文) 降到 O(当前块)。
///
/// 冻结边界（两种，都是 `MarkdownRenderer.parseBlocks` 里的硬块边界，边界之前的块
/// 不会因后续文本而改变）：
///   1. 不在未闭合代码围栏内的**空行**之后 —— 其上的段落/列表/表格等已定型；
///   2. 代码围栏**闭合行**之后 —— 该代码块已定型。
///
/// 未定型的尾部每帧重解析：markdown 里未闭合的标记（`**`、``` 等）本就只有闭合后
/// 才生效，重解析尾部既保证正确、又不会让成本随全文增长。
///
/// 拼接的块间分隔符由 `MarkdownRenderer.separator(after:before:)` 精确给出，
/// 因此增量拼接的结果与一次性全量渲染逐字一致（不会多出或少掉空行）。
final class StreamingMarkdownRenderer {

    /// 已冻结的文本前缀：下一次传入必须是它的延长，否则整段作废重来。
    private var frozenText = ""
    /// 已冻结前缀渲染好的属性串。
    private var frozenAttributed = NSMutableAttributedString()
    /// 已冻结前缀最后一个块的种类（用于拼接收尾块时分隔符）。
    private var frozenLastKind: MarkdownBlockKind?
    /// 字体/颜色指纹：属性变了就整段作废。
    private var attrsFingerprint = ""

    func reset() {
        frozenText = ""
        frozenAttributed = NSMutableAttributedString()
        frozenLastKind = nil
        attrsFingerprint = ""
    }

    /// 渲染全文；内部只解析增量部分。
    func render(_ text: String, baseAttributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let fingerprint = Self.fingerprint(baseAttributes)
        if fingerprint != attrsFingerprint || !text.hasPrefix(frozenText) {
            reset()
            attrsFingerprint = fingerprint
        }

        // 1) 把新定型的块并入冻结前缀 —— 只解析「新冻结的这一段」。
        if let freeze = Self.freezeEnd(in: text, after: frozenText.count) {
            let start = text.index(text.startIndex, offsetBy: frozenText.count)
            let slice = String(text[start..<freeze])
            appendFrozen(MarkdownRenderer.renderDetailed(slice, baseAttributes: baseAttributes),
                         baseAttributes: baseAttributes)
            frozenText = String(text[text.startIndex..<freeze])
        }

        // 2) 未定型的尾部每帧重解析（长度只受限于「最后一个块」）。
        let out = NSMutableAttributedString(attributedString: frozenAttributed)
        let tailStart = text.index(text.startIndex, offsetBy: frozenText.count)
        if tailStart < text.endIndex {
            let tail = MarkdownRenderer.renderDetailed(String(text[tailStart...]), baseAttributes: baseAttributes)
            if out.length > 0, let last = frozenLastKind, let first = tail.firstKind {
                out.append(NSAttributedString(
                    string: MarkdownRenderer.separator(after: last, before: first),
                    attributes: baseAttributes))
            }
            out.append(tail.attributed)
        }
        return out
    }

    private func appendFrozen(_ result: MarkdownRenderResult, baseAttributes: [NSAttributedString.Key: Any]) {
        guard let newLast = result.lastKind else { return }
        if frozenAttributed.length > 0, let last = frozenLastKind, let first = result.firstKind {
            frozenAttributed.append(NSAttributedString(
                string: MarkdownRenderer.separator(after: last, before: first),
                attributes: baseAttributes))
        }
        frozenAttributed.append(result.attributed)
        frozenLastKind = newLast
    }

    /// 返回「可安全冻结到」的终点（`text` 上的 index）；没有新边界则返回 nil。
    private static func freezeEnd(in text: String, after offset: Int) -> String.Index? {
        guard offset < text.count else { return nil }
        let base = text.index(text.startIndex, offsetBy: offset)
        var idx = base
        let end = text.endIndex
        var inFence = false
        var freeze: String.Index?

        while idx < end {
            let lineStart = idx
            let newline = text[lineStart...].firstIndex(of: "\n")
            let lineEnd = newline ?? end
            let afterLine = newline.map { text.index(after: $0) } ?? end
            let line = text[lineStart..<lineEnd]

            if line.hasPrefix("```") {
                let wasInFence = inFence
                inFence.toggle()
                if wasInFence && !inFence {
                    freeze = afterLine          // 围栏闭合：该代码块定型
                }
            } else if !inFence && isBlank(line) {
                freeze = afterLine              // 空行：其上所有块定型
            }

            idx = afterLine
        }

        if let f = freeze, f > base {
            return f
        }
        return nil
    }

    private static func isBlank(_ line: Substring) -> Bool {
        for ch in line where ch != " " && ch != "\t" && ch != "\r" {
            return false
        }
        return true
    }

    private static func fingerprint(_ attrs: [NSAttributedString.Key: Any]) -> String {
        let font = attrs[.font] as? UIFont
        let color = attrs[.foregroundColor] as? UIColor
        return "\(font?.fontName ?? "")/\(font?.pointSize ?? 0)/\(color?.description ?? "")"
    }
}
