import SwiftUI

struct MarkdownTextView: View {
    enum Style {
        case standard
        case subdued
    }

    let markdown: String
    var style: Style = .standard
    var fillsWidth: Bool = true

    private var context: MarkdownRenderContext {
        MarkdownRenderContext(style: style, fillsWidth: fillsWidth)
    }

    var body: some View {
        MarkdownBlocksView(
            blocks: MarkdownBlock.parse(from: markdown),
            context: context
        )
        .modifier(FillWidthModifier(isEnabled: fillsWidth))
    }
}

private struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]
    let context: MarkdownRenderContext

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks) { block in
                MarkdownBlockRow(block: block, context: context)
            }
        }
        .modifier(FillWidthModifier(isEnabled: context.fillsWidth))
    }
}

private struct MarkdownBlockRow: View {
    let block: MarkdownBlock
    let context: MarkdownRenderContext

    var body: some View {
        switch block.kind {
        case .heading(let level, let text):
            MarkdownInlineText(text: text, font: context.headingFont(for: level), context: context)
        case .paragraph(let text):
            MarkdownInlineText(text: text, font: context.bodyFont, context: context)
        case .list(let list):
            MarkdownListView(list: list, context: context)
        case .quote(let blocks):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .fill(Color.secondary.opacity(context.style == .subdued ? 0.16 : 0.25))
                    .frame(width: 3)

                MarkdownBlocksView(blocks: blocks, context: context)
            }
            .padding(.leading, 2)
        case .thematicBreak:
            Divider()
        case .code(let language, let code):
            VStack(alignment: .leading, spacing: 8) {
                if let language, !language.isEmpty {
                    Text(language.uppercased())
                        .font(.system(size: context.style == .subdued ? 9 : 10, weight: .bold))
                        .foregroundStyle(context.secondaryForegroundStyle)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(size: context.style == .subdued ? 12 : 13, weight: .regular, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .foregroundStyle(context.primaryForegroundStyle)
                }
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.black.opacity(context.style == .subdued ? 0.03 : 0.045))
                )
            }
        case .table(let table):
            MarkdownTableView(table: table, context: context)
        }
    }
}

private struct MarkdownInlineText: View {
    let text: String
    let font: Font
    let context: MarkdownRenderContext

    var body: some View {
        Group {
            if let attributed = try? AttributedString(
                markdown: text,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            ) {
                Text(attributed)
            } else {
                Text(text)
            }
        }
        .font(font)
        .foregroundStyle(context.primaryForegroundStyle)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(FillWidthModifier(isEnabled: context.fillsWidth))
    }
}

private struct MarkdownListView: View {
    let list: MarkdownList
    let context: MarkdownRenderContext
    var depth: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(list.items.enumerated()), id: \.element.id) { index, item in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        markerView(for: item, index: index)
                            .frame(width: markerWidth(for: item, index: index), alignment: .trailing)
                            .padding(.top, 1)

                        VStack(alignment: .leading, spacing: 8) {
                            if !item.text.isEmpty {
                                MarkdownInlineText(text: item.text, font: context.bodyFont, context: context)
                            }

                            ForEach(item.children) { child in
                                MarkdownListView(list: child, context: context, depth: depth + 1)
                            }
                        }
                    }
                }
            }
        }
        .padding(.leading, CGFloat(depth) * 14)
        .modifier(FillWidthModifier(isEnabled: context.fillsWidth))
    }

    @ViewBuilder
    private func markerView(for item: MarkdownListItem, index: Int) -> some View {
        if let checkState = item.checkState {
            Image(systemName: checkState == .checked ? "checkmark.square.fill" : "square")
                .font(.system(size: context.style == .subdued ? 12 : 13, weight: .semibold))
                .foregroundStyle(context.secondaryForegroundStyle)
        } else if list.isOrdered {
            Text("\(list.startIndex + index).")
                .font(.system(size: context.style == .subdued ? 12 : 13, weight: .semibold))
                .foregroundStyle(context.secondaryForegroundStyle)
        } else {
            Text("\u{2022}")
                .font(.system(size: context.style == .subdued ? 13 : 14, weight: .semibold))
                .foregroundStyle(context.secondaryForegroundStyle)
        }
    }

    private func markerWidth(for item: MarkdownListItem, index: Int) -> CGFloat {
        if item.checkState != nil {
            return 18
        }

        if list.isOrdered {
            let label = "\(list.startIndex + index)."
            return max(CGFloat(label.count) * 8, 24)
        }

        return 18
    }
}

private struct MarkdownTableView: View {
    let table: MarkdownTable
    let context: MarkdownRenderContext

    private var columnCount: Int {
        max(table.headers.count, table.rows.map(\.count).max() ?? 0)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(spacing: 0) {
                rowView(cells: padded(table.headers), isHeader: true, rowIndex: 0)

                ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                    Divider()
                    rowView(cells: padded(row), isHeader: false, rowIndex: index + 1)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(context.style == .subdued ? 0.025 : 0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            )
        }
    }

    private func rowView(cells: [String], isHeader: Bool, rowIndex: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { column, cell in
                MarkdownInlineText(
                    text: cell,
                    font: isHeader ? context.tableHeaderFont : context.bodyFont,
                    context: context
                )
                .frame(minWidth: 120, alignment: alignment(for: table.alignment(at: column)))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(backgroundColor(isHeader: isHeader, rowIndex: rowIndex))

                if column < cells.count - 1 {
                    Divider()
                }
            }
        }
    }

    private func padded(_ cells: [String]) -> [String] {
        guard cells.count < columnCount else {
            return Array(cells.prefix(columnCount))
        }

        return cells + Array(repeating: "", count: columnCount - cells.count)
    }

    private func alignment(for alignment: MarkdownTable.Alignment) -> Alignment {
        switch alignment {
        case .leading:
            return .leading
        case .center:
            return .center
        case .trailing:
            return .trailing
        }
    }

    private func backgroundColor(isHeader: Bool, rowIndex: Int) -> Color {
        if isHeader {
            return Color.secondary.opacity(context.style == .subdued ? 0.08 : 0.11)
        }

        return rowIndex.isMultiple(of: 2)
            ? Color.clear
            : Color.secondary.opacity(context.style == .subdued ? 0.025 : 0.04)
    }
}

private struct MarkdownRenderContext {
    let style: MarkdownTextView.Style
    let fillsWidth: Bool

    func headingFont(for level: Int) -> Font {
        switch (style, level) {
        case (.subdued, 1):
            return .system(size: 20, weight: .semibold)
        case (.subdued, 2):
            return .system(size: 18, weight: .semibold)
        case (.subdued, 3):
            return .system(size: 16, weight: .medium)
        case (.subdued, _):
            return .system(size: 15, weight: .medium)
        case (.standard, 1):
            return .system(size: 24, weight: .bold)
        case (.standard, 2):
            return .system(size: 20, weight: .bold)
        case (.standard, 3):
            return .system(size: 18, weight: .semibold)
        case (.standard, _):
            return .system(size: 16, weight: .semibold)
        }
    }

    var bodyFont: Font {
        .system(size: style == .subdued ? 13 : 14, weight: .regular)
    }

    var tableHeaderFont: Font {
        .system(size: style == .subdued ? 12 : 13, weight: .semibold)
    }

    var primaryForegroundStyle: Color {
        style == .subdued ? Color.secondary.opacity(0.82) : Color.primary
    }

    var secondaryForegroundStyle: Color {
        style == .subdued ? Color.secondary.opacity(0.68) : Color.secondary
    }
}

private struct FillWidthModifier: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            content
        }
    }
}

private struct MarkdownBlock: Identifiable {
    enum Kind {
        case heading(level: Int, text: String)
        case paragraph(String)
        case list(MarkdownList)
        case quote([MarkdownBlock])
        case thematicBreak
        case code(language: String?, code: String)
        case table(MarkdownTable)
    }

    let id = UUID()
    let kind: Kind

    static func parse(from source: String) -> [MarkdownBlock] {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var parser = MarkdownParser(lines: normalized.components(separatedBy: "\n"))
        let blocks = parser.parseBlocks()

        if blocks.isEmpty {
            let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [MarkdownBlock(kind: .paragraph(trimmed))]
        }

        return blocks
    }
}

private struct MarkdownList: Identifiable {
    let id = UUID()
    let isOrdered: Bool
    let startIndex: Int
    let items: [MarkdownListItem]
}

private struct MarkdownListItem: Identifiable {
    enum CheckState {
        case unchecked
        case checked
    }

    let id = UUID()
    let text: String
    let checkState: CheckState?
    let children: [MarkdownList]
}

private struct MarkdownTable: Identifiable {
    enum Alignment {
        case leading
        case center
        case trailing
    }

    let id = UUID()
    let headers: [String]
    let alignments: [Alignment]
    let rows: [[String]]

    func alignment(at index: Int) -> Alignment {
        guard alignments.indices.contains(index) else { return .leading }
        return alignments[index]
    }
}

private struct MarkdownParser {
    let lines: [String]
    var index = 0

    mutating func parseBlocks() -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if let block = parseFencedCodeBlockIfNeeded() {
                blocks.append(block)
                continue
            }

            if let block = parseIndentedCodeBlockIfNeeded() {
                blocks.append(block)
                continue
            }

            if Self.isThematicBreak(trimmed) {
                blocks.append(MarkdownBlock(kind: .thematicBreak))
                index += 1
                continue
            }

            if let heading = Self.heading(from: trimmed) {
                blocks.append(MarkdownBlock(kind: .heading(level: heading.level, text: heading.text)))
                index += 1
                continue
            }

            if let table = parseTableIfNeeded() {
                blocks.append(MarkdownBlock(kind: .table(table)))
                continue
            }

            if Self.isQuoteLine(trimmed) {
                blocks.append(parseQuoteBlock())
                continue
            }

            if Self.parseListMarker(from: line) != nil {
                blocks.append(MarkdownBlock(kind: .list(parseList())))
                continue
            }

            if let paragraph = parseParagraph() {
                blocks.append(paragraph)
            }
        }

        return blocks
    }

    private mutating func parseParagraph() -> MarkdownBlock? {
        var paragraphLines: [String] = []

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                break
            }

            if !paragraphLines.isEmpty && startsNewBlock(at: index) {
                break
            }

            paragraphLines.append(line)
            index += 1
        }

        let text = paragraphLines.joined(separator: "\n").trimmingCharacters(in: .newlines)
        return text.isEmpty ? nil : MarkdownBlock(kind: .paragraph(text))
    }

    private mutating func parseQuoteBlock() -> MarkdownBlock {
        var quotedLines: [String] = []

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            guard Self.isQuoteLine(trimmed) else { break }

            quotedLines.append(Self.strippingQuoteMarker(from: line))
            index += 1

            if index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                quotedLines.append("")
                index += 1
            }
        }

        var nestedParser = MarkdownParser(lines: quotedLines)
        let nestedBlocks = nestedParser.parseBlocks()
        return MarkdownBlock(kind: .quote(nestedBlocks))
    }

    private mutating func parseList() -> MarkdownList {
        let firstMarker = Self.parseListMarker(from: lines[index]) ?? .fallback
        let isOrdered = firstMarker.isOrdered
        let baseIndent = firstMarker.indent
        let startIndex = firstMarker.number ?? 1
        var items: [MarkdownListItem] = []

        while index < lines.count {
            guard let marker = Self.parseListMarker(from: lines[index]),
                  marker.indent == baseIndent,
                  marker.isOrdered == isOrdered else {
                break
            }

            var textLines: [String] = []
            if !marker.text.isEmpty {
                textLines.append(marker.text)
            }

            index += 1
            var children: [MarkdownList] = []

            while index < lines.count {
                let line = lines[index]
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                if trimmed.isEmpty {
                    let nextIndex = index + 1
                    index = nextIndex
                    if nextIndex < lines.count, !textLines.isEmpty {
                        textLines.append("")
                    }
                    continue
                }

                if let nextMarker = Self.parseListMarker(from: line),
                   nextMarker.indent == baseIndent,
                   nextMarker.isOrdered == isOrdered {
                    break
                }

                if let nestedMarker = Self.parseListMarker(from: line), nestedMarker.indent > baseIndent {
                    children.append(parseList())
                    continue
                }

                let lineIndent = Self.leadingIndent(of: line)
                if lineIndent > baseIndent {
                    textLines.append(line.trimmingCharacters(in: .whitespaces))
                    index += 1
                    continue
                }

                if startsNewBlock(at: index) {
                    break
                }

                textLines.append(trimmed)
                index += 1
            }

            let text = textLines.joined(separator: "\n").trimmingCharacters(in: .newlines)
            items.append(
                MarkdownListItem(
                    text: text,
                    checkState: marker.checkState,
                    children: children
                )
            )
        }

        return MarkdownList(isOrdered: isOrdered, startIndex: startIndex, items: items)
    }

    private mutating func parseFencedCodeBlockIfNeeded() -> MarkdownBlock? {
        guard let fence = Self.fence(from: lines[index]) else { return nil }
        let language = fence.info.isEmpty ? nil : fence.info
        var codeLines: [String] = []

        index += 1

        while index < lines.count {
            if Self.isClosingFence(lines[index], matching: fence) {
                index += 1
                break
            }

            codeLines.append(lines[index])
            index += 1
        }

        return MarkdownBlock(kind: .code(language: language, code: codeLines.joined(separator: "\n")))
    }

    private mutating func parseIndentedCodeBlockIfNeeded() -> MarkdownBlock? {
        guard index < lines.count else { return nil }
        let line = lines[index]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        guard !trimmed.isEmpty,
              Self.leadingIndent(of: line) >= 4,
              Self.parseListMarker(from: line) == nil else {
            return nil
        }

        var codeLines: [String] = []

        while index < lines.count {
            let current = lines[index]
            let currentTrimmed = current.trimmingCharacters(in: .whitespaces)

            if currentTrimmed.isEmpty {
                codeLines.append("")
                index += 1
                continue
            }

            guard Self.leadingIndent(of: current) >= 4 else { break }

            codeLines.append(Self.removingIndent(from: current, count: 4))
            index += 1
        }

        return MarkdownBlock(kind: .code(language: nil, code: codeLines.joined(separator: "\n")))
    }

    private mutating func parseTableIfNeeded() -> MarkdownTable? {
        guard index + 1 < lines.count else { return nil }

        let headerLine = lines[index]
        let separatorLine = lines[index + 1]

        guard headerLine.contains("|"),
              let alignments = Self.parseTableAlignmentRow(separatorLine) else {
            return nil
        }

        let headers = Self.parseTableRow(headerLine)
        guard !headers.isEmpty else { return nil }

        let normalizedAlignments = alignments.count < headers.count
            ? alignments + Array(repeating: .leading, count: headers.count - alignments.count)
            : Array(alignments.prefix(headers.count))

        index += 2
        var rows: [[String]] = []

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            guard !trimmed.isEmpty, line.contains("|"), !startsNewBlock(at: index, ignoringTable: true) else {
                break
            }

            rows.append(Self.parseTableRow(line))
            index += 1
        }

        return MarkdownTable(headers: headers, alignments: normalizedAlignments, rows: rows)
    }

    private func startsNewBlock(at lineIndex: Int, ignoringTable: Bool = false) -> Bool {
        guard lines.indices.contains(lineIndex) else { return false }

        let line = lines[lineIndex]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            return true
        }

        if Self.fence(from: line) != nil {
            return true
        }

        if Self.leadingIndent(of: line) >= 4 && Self.parseListMarker(from: line) == nil {
            return true
        }

        if Self.isThematicBreak(trimmed) || Self.heading(from: trimmed) != nil || Self.isQuoteLine(trimmed) {
            return true
        }

        if Self.parseListMarker(from: line) != nil {
            return true
        }

        if !ignoringTable, lineIndex + 1 < lines.count,
           lines[lineIndex].contains("|"),
           Self.parseTableAlignmentRow(lines[lineIndex + 1]) != nil {
            return true
        }

        return false
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        let marker = line.prefix { $0 == "#" }
        guard (1...6).contains(marker.count) else { return nil }

        let remainder = line.dropFirst(marker.count)
        guard remainder.first == " " else { return nil }

        let text = remainder.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (marker.count, text)
    }

    private static func isQuoteLine(_ line: String) -> Bool {
        line.hasPrefix(">")
    }

    private static func strippingQuoteMarker(from line: String) -> String {
        let trimmedPrefix = String(line.drop(while: { $0 == " " || $0 == "\t" }))
        guard trimmedPrefix.hasPrefix(">") else { return line }

        var result = String(trimmedPrefix.dropFirst())
        if result.first == " " {
            result.removeFirst()
        }
        return result
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        let normalized = line.replacingOccurrences(of: " ", with: "")
        return normalized == "---" || normalized == "***" || normalized == "___"
    }

    private static func leadingIndent(of line: String) -> Int {
        var count = 0

        for character in line {
            if character == " " {
                count += 1
            } else if character == "\t" {
                count += 4
            } else {
                break
            }
        }

        return count
    }

    private static func removingIndent(from line: String, count: Int) -> String {
        var remaining = count
        var currentIndex = line.startIndex

        while currentIndex < line.endIndex, remaining > 0 {
            let character = line[currentIndex]
            if character == " " {
                remaining -= 1
            } else if character == "\t" {
                remaining -= min(4, remaining)
            } else {
                break
            }

            currentIndex = line.index(after: currentIndex)
        }

        return String(line[currentIndex...])
    }

    private static func parseTableRow(_ line: String) -> [String] {
        var working = line.trimmingCharacters(in: .whitespaces)
        if working.hasPrefix("|") {
            working.removeFirst()
        }
        if working.hasSuffix("|") {
            working.removeLast()
        }

        return working
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func parseTableAlignmentRow(_ line: String) -> [MarkdownTable.Alignment]? {
        let cells = parseTableRow(line)
        guard !cells.isEmpty else { return nil }

        var alignments: [MarkdownTable.Alignment] = []

        for cell in cells {
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }

            let dashes = trimmed.filter { $0 == "-" }.count
            guard dashes >= 3,
                  trimmed.allSatisfy({ $0 == "-" || $0 == ":" }) else {
                return nil
            }

            if trimmed.hasPrefix(":"), trimmed.hasSuffix(":") {
                alignments.append(.center)
            } else if trimmed.hasSuffix(":") {
                alignments.append(.trailing)
            } else {
                alignments.append(.leading)
            }
        }

        return alignments
    }

    private static func fence(from line: String) -> Fence? {
        let trimmed = String(line.drop(while: { $0 == " " || $0 == "\t" }))
        guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }

        let count = trimmed.prefix { $0 == marker }.count
        guard count >= 3 else { return nil }

        let info = String(trimmed.dropFirst(count)).trimmingCharacters(in: .whitespaces)
        return Fence(marker: marker, count: count, info: info)
    }

    private static func isClosingFence(_ line: String, matching fence: Fence) -> Bool {
        let trimmed = String(line.drop(while: { $0 == " " || $0 == "\t" }))
        guard trimmed.allSatisfy({ $0 == fence.marker || $0 == " " || $0 == "\t" }) else {
            return false
        }

        let count = trimmed.prefix { $0 == fence.marker }.count
        return count >= fence.count
    }

    private static func parseListMarker(from line: String) -> ListMarker? {
        let indent = leadingIndent(of: line)
        let trimmed = String(line.drop(while: { $0 == " " || $0 == "\t" }))
        guard !trimmed.isEmpty else { return nil }

        if let bullet = trimmed.first, bullet == "-" || bullet == "*" || bullet == "+" {
            let afterMarker = trimmed.dropFirst()
            guard afterMarker.first?.isWhitespace == true else { return nil }

            let body = String(afterMarker.drop(while: { $0.isWhitespace }))
            let task = parseTaskState(from: body)
            return ListMarker(
                indent: indent,
                number: nil,
                isOrdered: false,
                text: task.text,
                checkState: task.checkState
            )
        }

        let digitCount = trimmed.prefix { $0.isNumber }.count

        guard digitCount > 0 else { return nil }

        let markerEndIndex = trimmed.index(trimmed.startIndex, offsetBy: digitCount)
        guard markerEndIndex < trimmed.endIndex else { return nil }

        let delimiter = trimmed[markerEndIndex]
        guard delimiter == "." || delimiter == ")" else { return nil }

        let afterDelimiter = trimmed.index(after: markerEndIndex)
        guard afterDelimiter < trimmed.endIndex, trimmed[afterDelimiter].isWhitespace else { return nil }

        let number = Int(trimmed[..<markerEndIndex]) ?? 1
        let body = String(trimmed[afterDelimiter...]).trimmingCharacters(in: .whitespaces)
        let task = parseTaskState(from: body)

        return ListMarker(
            indent: indent,
            number: number,
            isOrdered: true,
            text: task.text,
            checkState: task.checkState
        )
    }

    private static func parseTaskState(from text: String) -> (text: String, checkState: MarkdownListItem.CheckState?) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3, trimmed.first == "[" else {
            return (trimmed, nil)
        }

        let characters = Array(trimmed)
        guard characters.count >= 4, characters[2] == "]" else {
            return (trimmed, nil)
        }

        let marker = characters[1]
        let state: MarkdownListItem.CheckState?
        switch marker {
        case " ", "-":
            state = .unchecked
        case "x", "X":
            state = .checked
        default:
            state = nil
        }

        guard let state else {
            return (trimmed, nil)
        }

        let startIndex = trimmed.index(trimmed.startIndex, offsetBy: 3)
        let remainder = String(trimmed[startIndex...]).trimmingCharacters(in: .whitespaces)
        return (remainder, state)
    }

    private struct Fence {
        let marker: Character
        let count: Int
        let info: String
    }

    private struct ListMarker {
        static let fallback = ListMarker(indent: 0, number: nil, isOrdered: false, text: "", checkState: nil)

        let indent: Int
        let number: Int?
        let isOrdered: Bool
        let text: String
        let checkState: MarkdownListItem.CheckState?
    }
}
