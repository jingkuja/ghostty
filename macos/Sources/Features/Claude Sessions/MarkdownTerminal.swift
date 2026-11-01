import Foundation

/// Renders Markdown as ANSI-styled text for reading in a terminal pager (`less -R`).
///
/// Parsing is Foundation's (`AttributedString(markdown:)` with full syntax, which covers
/// CommonMark plus GitHub tables and strikethrough); this only lays the parsed blocks
/// out: word wrapping that knows CJK characters are two cells wide, list markers,
/// quote bars, framed code blocks and box-drawn tables. Links are OSC 8 hyperlinks,
/// which `less -R` passes through.
enum MarkdownTerminal {
    static func isMarkdown(_ path: String) -> Bool {
        ["md", "markdown", "mdown", "mkd", "mdx"].contains((path as NSString).pathExtension.lowercased())
    }

    /// The document laid out for a terminal `columns` wide.
    static func render(_ markdown: String, columns: Int) -> String {
        let source = fencingFrontMatter(markdown)
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard let document = try? AttributedString(markdown: source, options: options) else {
            return markdown
        }
        var renderer = Renderer(width: max(20, min(columns, 110) - 2 * margin.count))
        renderer.render(blocks(of: document))
        return renderer.lines.map { $0.isEmpty ? "" : margin + $0 }.joined(separator: "\n") + "\n"
    }

    private static let margin = "  "

    /// YAML front matter would otherwise parse as a rule followed by a heading.
    private static func fencingFrontMatter(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else { return normalized }
        let body = normalized.dropFirst(4) + "\n"
        guard let end = body.range(of: "\n---\n") else { return normalized }
        return "```yaml\n" + body[..<end.lowerBound] + "\n```\n" + body[end.upperBound...]
    }

    // MARK: Blocks

    fileprivate struct Span {
        var text: String
        var inline: InlinePresentationIntent
        var link: URL?
        var image: URL?
    }

    fileprivate struct Block {
        /// Innermost first, as Foundation reports them.
        var components: [PresentationIntent.IntentType]
        var spans: [Span]

        var kind: PresentationIntent.Kind { components.first?.kind ?? .paragraph }
        var text: String { spans.map(\.text).joined() }

        var table: PresentationIntent.IntentType? {
            components.first { if case .table = $0.kind { return true } else { return false } }
        }

        /// Identities of the lists and quotes this block sits in.
        var containers: Set<Int> {
            Set(components.compactMap {
                switch $0.kind {
                case .orderedList, .unorderedList, .blockQuote: return $0.identity
                default: return nil
                }
            })
        }

        var lists: Set<Int> {
            Set(components.compactMap {
                switch $0.kind {
                case .orderedList, .unorderedList: return $0.identity
                default: return nil
                }
            })
        }
    }

    /// Consecutive runs with the same block intent, in document order.
    private static func blocks(of document: AttributedString) -> [Block] {
        var result: [Block] = []
        var current: PresentationIntent?
        for run in document.runs {
            let span = Span(
                text: String(document[run.range].characters),
                inline: run.inlinePresentationIntent ?? [],
                link: run.link,
                image: run.imageURL)
            if let last = result.indices.last, run.presentationIntent == current {
                result[last].spans.append(span)
            } else {
                current = run.presentationIntent
                result.append(Block(components: run.presentationIntent?.components ?? [], spans: [span]))
            }
        }
        return result
    }

    // MARK: Layout

    private struct Renderer {
        let width: Int
        var lines: [String] = []
        private var markedItems: Set<Int> = []
        private var previous: Block?

        init(width: Int) { self.width = width }

        mutating func render(_ blocks: [Block]) {
            var index = 0
            while index < blocks.count {
                let block = blocks[index]
                if let table = block.table {
                    var end = index
                    while end < blocks.count, blocks[end].table?.identity == table.identity { end += 1 }
                    renderTable(Array(blocks[index..<end]), intent: table)
                    previous = block
                    index = end
                } else {
                    renderBlock(block)
                    previous = block
                    index += 1
                }
            }
        }

        // MARK: Prefixes

        /// The prefixes for a block's first and later lines: quote bars and list markers.
        private mutating func prefixes(for block: Block) -> (first: Styled, rest: Styled) {
            var first = Styled()
            var rest = Styled()
            let outerFirst = Array(block.components.reversed())
            var listDepth = 0
            for (position, component) in outerFirst.enumerated() {
                switch component.kind {
                case .blockQuote:
                    first.append("│ ", style: Style.quoteBar)
                    rest.append("│ ", style: Style.quoteBar)
                case .listItem(let ordinal):
                    let parent = position > 0 ? outerFirst[position - 1].kind : .unorderedList
                    let marker: String
                    if case .orderedList = parent {
                        marker = "\(ordinal). "
                    } else {
                        marker = ["• ", "◦ ", "▪ "][listDepth % 3]
                    }
                    listDepth += 1
                    let blank = String(repeating: " ", count: displayWidth(marker))
                    if markedItems.insert(component.identity).inserted {
                        first.append(marker, style: Style.listMarker)
                    } else {
                        first.append(blank, style: [])
                    }
                    rest.append(blank, style: [])
                default:
                    break
                }
            }
            return (first, rest)
        }

        /// Paragraphs of different items in one list are tight; anything else, including a
        /// further paragraph of the same item, gets a blank line between, which keeps the
        /// bars of a quote that continues across it.
        private mutating func separate(from block: Block, rest: Styled) {
            guard let previous, !lines.isEmpty else { return }
            if !previous.lists.isDisjoint(with: block.lists), isListParagraph(previous), isListParagraph(block),
               let item = block.components.first(where: { if case .listItem = $0.kind { return true } else { return false } }),
               !previous.components.contains(where: { $0.identity == item.identity }) {
                return
            }
            if previous.containers.isDisjoint(with: block.containers) {
                lines.append("")
            } else {
                lines.append(rest.rendered)
            }
        }

        private func isListParagraph(_ block: Block) -> Bool {
            if case .paragraph = block.kind { return true }
            return false
        }

        // MARK: Blocks

        private mutating func renderBlock(_ block: Block) {
            let (first, rest) = prefixes(for: block)
            separate(from: block, rest: rest)
            let available = max(10, width - first.width)
            let quoted = block.components.contains { if case .blockQuote = $0.kind { return true } else { return false } }

            switch block.kind {
            case .header(let level):
                let style = Style.header(level)
                let wrapped = wrap(atoms(block.spans, base: style), width: available)
                emit(wrapped, first: first, rest: rest)
                if level <= 2 {
                    let rule = String(repeating: level == 1 ? "━" : "─", count: min(available, wrapped.map(\.width).max() ?? 0))
                    lines.append(rest.rendered + Style.apply(level == 1 ? Style.h1 : Style.h2, rule))
                }

            case .codeBlock(let language):
                renderCode(block.text, language: language, first: first, rest: rest)

            case .thematicBreak:
                lines.append(first.rendered + Style.apply(Style.rule, String(repeating: "─", count: available)))

            default:
                var spans = block.spans
                if !block.lists.isEmpty { taskMarker(&spans) }
                let wrapped = wrap(atoms(spans, base: quoted ? Style.quote : []), width: available)
                emit(wrapped, first: first, rest: rest)
            }
        }

        /// GitHub task list items, `[ ]` and `[x]`, which Foundation leaves as text.
        private func taskMarker(_ spans: inout [Span]) {
            guard let text = spans.first?.text else { return }
            for (raw, box) in [("[ ] ", "☐ "), ("[x] ", "☑ "), ("[X] ", "☑ ")] where text.hasPrefix(raw) {
                spans[0].text = box + text.dropFirst(raw.count)
                return
            }
        }

        private mutating func renderCode(_ text: String, language: String?, first: Styled, rest: Styled) {
            var body = text.replacingOccurrences(of: "\t", with: "    ")
            if body.hasSuffix("\n") { body.removeLast() }
            let label = language.map { $0.isEmpty ? "" : " " + $0 } ?? ""
            lines.append(first.rendered + Style.apply(Style.codeFrame, "┌─" + label))
            for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append(rest.rendered + Style.apply(Style.codeFrame, "│ ") + Style.apply(Style.code, String(line)))
            }
            lines.append(rest.rendered + Style.apply(Style.codeFrame, "└─"))
        }

        private mutating func renderTable(_ cells: [Block], intent: PresentationIntent.IntentType) {
            guard case .table(let columns) = intent.kind, let firstCell = cells.first else { return }
            let (first, rest) = prefixes(for: firstCell)
            separate(from: firstCell, rest: rest)

            // Rows in order, each a column-indexed list of cells.
            var rows: [(header: Bool, cells: [Int: [Atom]])] = []
            var rowIdentity: Int?
            for cell in cells {
                guard let row = cell.components.first(where: {
                    switch $0.kind {
                    case .tableHeaderRow, .tableRow: return true
                    default: return false
                    }
                }) else { continue }
                if row.identity != rowIdentity {
                    rowIdentity = row.identity
                    if case .tableHeaderRow = row.kind { rows.append((true, [:])) } else { rows.append((false, [:])) }
                }
                guard case .tableCell(let column) = cell.kind else { continue }
                rows[rows.count - 1].cells[column] = atoms(cell.spans, base: rows[rows.count - 1].header ? Style.tableHeader : [])
            }
            let count = max(columns.count, rows.map { ($0.cells.keys.max() ?? -1) + 1 }.max() ?? 0)
            guard count > 0 else { return }

            // Natural widths, then shrink the widest columns until the frame fits.
            var widths = (0..<count).map { column in
                rows.map { row in natural(row.cells[column] ?? []) }.max() ?? 0
            }.map { max(1, $0) }
            let frame = 3 * count + 1
            let available = max(count * 4, width - first.width - frame)
            while widths.reduce(0, +) > available, let widest = widths.indices.max(by: { widths[$0] < widths[$1] }),
                  widths[widest] > 4 {
                widths[widest] -= 1
            }

            func border(_ left: String, _ middle: String, _ right: String) -> String {
                Style.apply(Style.tableFrame, left + widths.map { String(repeating: "─", count: $0 + 2) }.joined(separator: middle) + right)
            }

            lines.append(first.rendered + border("┌", "┬", "┐"))
            for (index, row) in rows.enumerated() {
                let wrapped = (0..<count).map { wrap(row.cells[$0] ?? [], width: widths[$0], hanging: false) }
                let height = max(1, wrapped.map(\.count).max() ?? 1)
                for line in 0..<height {
                    var text = rest.rendered + Style.apply(Style.tableFrame, "│")
                    for column in 0..<count {
                        let cell = line < wrapped[column].count ? wrapped[column][line] : Line()
                        let gap = widths[column] - cell.width
                        let alignment = column < columns.count ? columns[column].alignment : .left
                        let left = switch alignment {
                        case .center: gap / 2
                        case .right: gap
                        default: 0
                        }
                        text += " " + String(repeating: " ", count: max(0, left)) + cell.text
                            + String(repeating: " ", count: max(0, gap - left)) + " " + Style.apply(Style.tableFrame, "│")
                    }
                    lines.append(text)
                }
                if row.header && index < rows.count - 1 {
                    lines.append(rest.rendered + border("├", "┼", "┤"))
                }
            }
            lines.append(rest.rendered + border("└", "┴", "┘"))
        }

        private mutating func emit(_ wrapped: [Line], first: Styled, rest: Styled) {
            for (index, line) in (wrapped.isEmpty ? [Line()] : wrapped).enumerated() {
                lines.append((index == 0 ? first : rest).rendered + line.text)
            }
        }
    }

    // MARK: Inline text

    fileprivate struct Atom {
        enum Kind { case word, space, softSpace, newline }
        var kind: Kind
        var text: String
        var style: [Int]
        var link: URL?
        var width: Int
        var wide: Bool
    }

    fileprivate struct Line {
        var text = ""
        var width = 0
    }

    /// Spans split into words, single CJK characters (which can break anywhere) and spaces.
    private static func atoms(_ spans: [Span], base: [Int]) -> [Atom] {
        var result: [Atom] = []
        for span in spans {
            var style = base
            if span.inline.contains(.stronglyEmphasized) { style.append(1) }
            if span.inline.contains(.emphasized) { style.append(3) }
            if span.inline.contains(.strikethrough) { style.append(9) }
            if span.inline.contains(.code) { style += Style.code }
            if span.inline.contains(.inlineHTML) || span.inline.contains(.blockHTML) { style += Style.html }
            if span.link != nil { style += Style.link }

            if span.inline.contains(.softBreak) {
                result.append(Atom(kind: .softSpace, text: " ", style: [], width: 1, wide: false))
                continue
            }
            if span.inline.contains(.lineBreak) {
                result.append(Atom(kind: .newline, text: "", style: [], width: 0, wide: false))
                continue
            }

            var text = span.text
            if let image = span.image {
                text = "🖼 " + (text.isEmpty ? image.lastPathComponent : text)
                style += Style.link
            }

            var word = ""
            func flush() {
                guard !word.isEmpty else { return }
                result.append(Atom(kind: .word, text: word, style: style, link: span.link ?? span.image,
                                   width: displayWidth(word), wide: false))
                word = ""
            }
            for character in text {
                if character == "\n" {
                    flush()
                    result.append(Atom(kind: .newline, text: "", style: [], width: 0, wide: false))
                } else if character == " " || character == "\t" {
                    flush()
                    result.append(Atom(kind: .space, text: " ", style: style, link: span.link, width: 1, wide: false))
                } else if displayWidth(character) == 2 {
                    flush()
                    result.append(Atom(kind: .word, text: String(character), style: style, link: span.link ?? span.image,
                                       width: 2, wide: true))
                } else {
                    word.append(character)
                }
            }
            flush()
        }

        // A source line break between two CJK characters is not a space.
        for index in result.indices where result[index].kind == .softSpace {
            let before = result[..<index].last { $0.kind == .word }
            let after = result[(index + 1)...].first { $0.kind == .word }
            result[index].kind = .space
            if before?.wide == true && after?.wide == true { result[index].width = 0 }
        }
        return result
    }

    /// Punctuation that shouldn't start a line.
    private static let closingPunctuation = CharacterSet(charactersIn: "，。、；：！？）」』】》〉”’…,.;:!?)]}")

    /// The width of the cell's text unwrapped, capped so one long cell doesn't dominate.
    private static func natural(_ atoms: [Atom]) -> Int {
        var widest = 0
        var current = 0
        for atom in atoms {
            if atom.kind == .newline {
                widest = max(widest, current)
                current = 0
            } else {
                current += atom.width
            }
        }
        return min(60, max(widest, current))
    }

    /// Greedy line filling. A word longer than a line is split across lines. With
    /// `hanging`, closing punctuation stays at the end of a line even past its width,
    /// rather than starting the next one; the right margin leaves room for it.
    private static func wrap(_ atoms: [Atom], width: Int, hanging: Bool = true) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        var pending: Atom?
        var started = false
        // Neighbouring atoms with the same style and link are written as one escape run.
        var run: Atom?

        func put(_ atom: Atom) {
            if run?.style == atom.style, run?.link == atom.link {
                run?.text += atom.text
            } else {
                if let run { line.text += Style.render(run) }
                run = atom
            }
            line.width += atom.width
        }

        func flush() {
            if let run { line.text += Style.render(run) }
            run = nil
            lines.append(line)
            line = Line()
            pending = nil
            started = false
        }

        for atom in atoms {
            switch atom.kind {
            case .newline:
                flush()
            case .space, .softSpace:
                if started && atom.width > 0 { pending = atom }
            case .word where atom.width > width:
                if started {
                    if let gap = pending, line.width + gap.width < width - 1 { put(gap) } else { flush() }
                    pending = nil
                }
                var piece = atom
                piece.text = ""
                piece.width = 0
                for character in atom.text {
                    let characterWidth = displayWidth(character)
                    if line.width + piece.width + characterWidth > width, line.width + piece.width > 0 {
                        put(piece)
                        flush()
                        piece.text = ""
                        piece.width = 0
                    }
                    piece.text.append(character)
                    piece.width += characterWidth
                }
                put(piece)
                started = true
            case .word:
                let space = pending?.width ?? 0
                let hangs = hanging && pending == nil && atom.text.count == 1
                    && closingPunctuation.contains(atom.text.unicodeScalars.first!)
                if started && line.width + space + atom.width > width && !hangs {
                    flush()
                }
                if let gap = pending {
                    put(gap)
                    pending = nil
                }
                put(atom)
                started = true
            }
        }
        if started || lines.isEmpty { flush() }
        return lines
    }

    // MARK: Styling

    fileprivate struct Styled {
        var rendered = ""
        var width = 0

        mutating func append(_ text: String, style: [Int]) {
            rendered += Style.apply(style, text)
            width += displayWidth(text)
        }
    }

    private enum Style {
        static let h1 = [1, 35]
        static let h2 = [1, 34]
        static let code = [36]
        static let codeFrame = [90]
        static let link = [4, 34]
        static let html = [90]
        static let quote = [3, 90]
        static let quoteBar = [90]
        static let listMarker = [33]
        static let rule = [90]
        static let tableFrame = [90]
        static let tableHeader = [1]

        static func header(_ level: Int) -> [Int] {
            switch level {
            case 1: h1
            case 2: h2
            case 3: [1, 32]
            default: [1]
            }
        }

        static func apply(_ style: [Int], _ text: String) -> String {
            guard !style.isEmpty, !text.isEmpty else { return text }
            return "\u{1B}[" + style.map(String.init).joined(separator: ";") + "m" + text + "\u{1B}[0m"
        }

        static func render(_ atom: Atom) -> String {
            let styled = apply(atom.style, atom.text)
            guard let link = atom.link?.absoluteString, !link.isEmpty else { return styled }
            return "\u{1B}]8;;" + link + "\u{1B}\\" + styled + "\u{1B}]8;;\u{1B}\\"
        }
    }

    // MARK: Width

    fileprivate static func displayWidth(_ text: String) -> Int {
        text.reduce(0) { $0 + displayWidth($1) }
    }

    fileprivate static func displayWidth(_ character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 0 }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format, .control: return 0
        default: break
        }
        if scalar.properties.isEmojiPresentation || character.unicodeScalars.contains("\u{FE0F}") { return 2 }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }
}
