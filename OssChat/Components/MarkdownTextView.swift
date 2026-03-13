import SwiftUI

struct MarkdownTextView: View {
    enum Style {
        case standard
        case subdued
    }

    let markdown: String
    var style: Style = .standard

    private var blocks: [MarkdownBlock] {
        MarkdownBlock.parse(from: markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks) { block in
                switch block.kind {
                case .heading(let level, let text):
                    inlineText(text, font: headingFont(for: level))
                case .paragraph(let text):
                    inlineText(text, font: bodyFont)
                case .unorderedList(let items):
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\u{2022}")
                                    .font(.system(size: bulletFontSize, weight: .semibold))
                                    .foregroundStyle(secondaryForegroundStyle)
                                inlineText(item, font: bodyFont)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                case .orderedList(let items):
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(index + 1).")
                                    .font(.system(size: orderedListFontSize, weight: .semibold))
                                    .foregroundStyle(secondaryForegroundStyle)
                                inlineText(item, font: bodyFont)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                case .quote(let text):
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 999, style: .continuous)
                            .fill(Color.secondary.opacity(style == .subdued ? 0.16 : 0.25))
                            .frame(width: 3)
                        inlineText(text, font: bodyFont)
                            .foregroundStyle(secondaryForegroundStyle)
                    }
                    .padding(.leading, 2)
                case .thematicBreak:
                    Divider()
                case .code(let language, let code):
                    VStack(alignment: .leading, spacing: 8) {
                        if let language, !language.isEmpty {
                            Text(language.uppercased())
                                .font(.system(size: style == .subdued ? 9 : 10, weight: .bold))
                                .foregroundStyle(secondaryForegroundStyle)
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(code)
                                .font(.system(size: style == .subdued ? 12 : 13, weight: .regular, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .foregroundStyle(primaryForegroundStyle)
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.black.opacity(style == .subdued ? 0.03 : 0.045))
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func inlineText(_ text: String, font: Font) -> some View {
        if let attributed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) {
            Text(attributed)
                .font(font)
                .foregroundStyle(primaryForegroundStyle)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(text)
                .font(font)
                .foregroundStyle(primaryForegroundStyle)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func headingFont(for level: Int) -> Font {
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

    private var bodyFont: Font {
        .system(size: style == .subdued ? 13 : 14, weight: style == .subdued ? .regular : .regular)
    }

    private var bulletFontSize: CGFloat {
        style == .subdued ? 13 : 14
    }

    private var orderedListFontSize: CGFloat {
        style == .subdued ? 12 : 13
    }

    private var primaryForegroundStyle: Color {
        style == .subdued ? Color.secondary.opacity(0.82) : Color.primary
    }

    private var secondaryForegroundStyle: Color {
        style == .subdued ? Color.secondary.opacity(0.68) : Color.secondary
    }
}

private struct MarkdownBlock: Identifiable {
    enum Kind {
        case heading(level: Int, text: String)
        case paragraph(String)
        case unorderedList([String])
        case orderedList([String])
        case quote(String)
        case thematicBreak
        case code(language: String?, code: String)
    }

    let id = UUID()
    let kind: Kind

    static func parse(from source: String) -> [MarkdownBlock] {
        let lines = source.components(separatedBy: .newlines)
        var blocks: [MarkdownBlock] = []
        var paragraphBuffer: [String] = []
        var index = 0

        func flushParagraph() {
            let text = paragraphBuffer.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !text.isEmpty {
                blocks.append(MarkdownBlock(kind: .paragraph(text)))
            }
            paragraphBuffer.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                flushParagraph()
                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1

                while index < lines.count, !lines[index].hasPrefix("```") {
                    codeLines.append(lines[index])
                    index += 1
                }

                blocks.append(
                    MarkdownBlock(
                        kind: .code(
                            language: language.isEmpty ? nil : language,
                            code: codeLines.joined(separator: "\n")
                        )
                    )
                )
                index += 1
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if isThematicBreak(trimmed) {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .thematicBreak))
                index += 1
                continue
            }

            if let heading = heading(from: trimmed) {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .heading(level: heading.level, text: heading.text)))
                index += 1
                continue
            }

            if isQuoteLine(trimmed) {
                flushParagraph()
                var quoteLines: [String] = []
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard isQuoteLine(current) else { break }
                    quoteLines.append(String(current.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(MarkdownBlock(kind: .quote(quoteLines.joined(separator: "\n"))))
                continue
            }

            if let listItem = unorderedListItem(from: trimmed) {
                flushParagraph()
                var items: [String] = [listItem]
                index += 1

                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard let item = unorderedListItem(from: current) else { break }
                    items.append(item)
                    index += 1
                }

                blocks.append(MarkdownBlock(kind: .unorderedList(items)))
                continue
            }

            if let listItem = orderedListItem(from: trimmed) {
                flushParagraph()
                var items: [String] = [listItem]
                index += 1

                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard let item = orderedListItem(from: current) else { break }
                    items.append(item)
                    index += 1
                }

                blocks.append(MarkdownBlock(kind: .orderedList(items)))
                continue
            }

            paragraphBuffer.append(line)
            index += 1
        }

        flushParagraph()
        return blocks
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        let marker = line.prefix { $0 == "#" }
        guard (1...6).contains(marker.count) else { return nil }

        let remainder = line.dropFirst(marker.count)
        guard remainder.first == " " else { return nil }

        let text = remainder.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (marker.count, text)
    }

    private static func unorderedListItem(from line: String) -> String? {
        guard line.count >= 2 else { return nil }
        let marker = line.prefix(2)
        guard marker == "- " || marker == "* " || marker == "+ " else { return nil }
        let text = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    private static func orderedListItem(from line: String) -> String? {
        guard let separatorIndex = line.firstIndex(of: ".") else { return nil }
        let number = line[..<separatorIndex]
        guard !number.isEmpty, number.allSatisfy(\.isNumber) else { return nil }

        let remainderStart = line.index(after: separatorIndex)
        guard remainderStart < line.endIndex, line[remainderStart] == " " else { return nil }

        let text = line[line.index(after: remainderStart)...].trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    private static func isQuoteLine(_ line: String) -> Bool {
        line.hasPrefix(">")
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        let normalized = line.replacingOccurrences(of: " ", with: "")
        return normalized == "---" || normalized == "***" || normalized == "___"
    }
}
