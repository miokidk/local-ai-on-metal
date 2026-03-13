import SwiftUI

struct MarkdownTextView: View {
    let markdown: String

    private var segments: [MarkdownSegment] {
        MarkdownSegment.parse(from: markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(segments) { segment in
                switch segment.kind {
                case .markdown(let text):
                    if let attributed = try? AttributedString(
                        markdown: text,
                        options: AttributedString.MarkdownParsingOptions(
                            interpretedSyntax: .full,
                            failurePolicy: .returnPartiallyParsedIfPossible
                        )
                    ) {
                        Text(attributed)
                            .font(.system(size: 14))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(text)
                            .font(.system(size: 14))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .code(let language, let code):
                    VStack(alignment: .leading, spacing: 8) {
                        if let language, !language.isEmpty {
                            Text(language.uppercased())
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.secondary)
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(code)
                                .font(.system(size: 13, weight: .regular, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.black.opacity(0.045))
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownSegment: Identifiable {
    enum Kind {
        case markdown(String)
        case code(language: String?, code: String)
    }

    let id = UUID()
    let kind: Kind

    static func parse(from source: String) -> [MarkdownSegment] {
        let lines = source.components(separatedBy: .newlines)
        var segments: [MarkdownSegment] = []
        var buffer: [String] = []
        var codeBuffer: [String] = []
        var activeLanguage: String?
        var isInCodeFence = false

        func flushMarkdown() {
            let text = buffer.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !text.isEmpty {
                segments.append(MarkdownSegment(kind: .markdown(text)))
            }
            buffer.removeAll(keepingCapacity: true)
        }

        func flushCode() {
            let code = codeBuffer.joined(separator: "\n")
            if !code.isEmpty {
                segments.append(MarkdownSegment(kind: .code(language: activeLanguage, code: code)))
            }
            codeBuffer.removeAll(keepingCapacity: true)
            activeLanguage = nil
        }

        for line in lines {
            if line.hasPrefix("```") {
                if isInCodeFence {
                    flushCode()
                    isInCodeFence = false
                } else {
                    flushMarkdown()
                    activeLanguage = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    isInCodeFence = true
                }
                continue
            }

            if isInCodeFence {
                codeBuffer.append(line)
            } else {
                buffer.append(line)
            }
        }

        if isInCodeFence {
            flushCode()
        } else {
            flushMarkdown()
        }

        return segments
    }
}
