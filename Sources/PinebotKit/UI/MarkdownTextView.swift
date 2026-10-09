import SwiftUI
import AppKit

/// Renders formatted Markdown text in SwiftUI, supporting headers, bullet lists,
/// code blocks with copy functionality, and inline styles (bold, italic, inline code).
public struct MarkdownTextView: View {
    public let content: String
    public let baseFontSize: CGFloat
    public let isPinebotMessage: Bool
    
    public init(content: String, baseFontSize: CGFloat = 14.0, isPinebotMessage: Bool = true) {
        self.content = content
        self.baseFontSize = baseFontSize
        self.isPinebotMessage = isPinebotMessage
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let blocks = parseMarkdownBlocks(content)
            ForEach(0..<blocks.count, id: \.self) { index in
                renderBlock(blocks[index])
            }
        }
    }
    
    @ViewBuilder
    private func renderBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case .header(let text, let level):
            Text(LocalizedStringKey(text))
                .font(.system(size: level == 1 ? baseFontSize + 4 : baseFontSize + 2, weight: .bold))
                .foregroundColor(textColor)
                .padding(.top, 4)
            
        case .paragraph(let text):
            Text(LocalizedStringKey(text))
                .font(.system(size: baseFontSize, weight: .regular))
                .foregroundColor(textColor)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            
        case .bullet(let text):
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                    .font(.system(size: baseFontSize, weight: .bold))
                    .foregroundColor(Color.pineEmerald)
                Text(LocalizedStringKey(text))
                    .font(.system(size: baseFontSize, weight: .regular))
                    .foregroundColor(textColor)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 4)
            
        case .codeBlock(let code, let language):
            VStack(alignment: .leading, spacing: 4) {
                if let lang = language, !lang.isEmpty {
                    HStack {
                        Text(lang.uppercased())
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(action: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                        }) {
                            HStack(spacing: 3) {
                                Image(systemName: "doc.on.doc")
                                Text("Copy")
                            }
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                }
                
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(size: baseFontSize - 1, design: .monospaced))
                        .foregroundColor(textColor)
                        .padding(10)
                        .textSelection(.enabled)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }
    
    private var textColor: Color {
        isPinebotMessage ? Color(nsColor: .labelColor) : Color.white
    }
    
    private enum MarkdownBlock {
        case header(text: String, level: Int)
        case paragraph(text: String)
        case bullet(text: String)
        case codeBlock(code: String, language: String?)
    }
    
    private func parseMarkdownBlocks(_ raw: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = raw.components(separatedBy: "\n")
        var inCodeBlock = false
        var codeAccumulator: [String] = []
        var codeLang: String? = nil
        var paragraphAccumulator: [String] = []
        
        func flushParagraph() {
            if !paragraphAccumulator.isEmpty {
                let joined = paragraphAccumulator.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !joined.isEmpty {
                    blocks.append(.paragraph(text: joined))
                }
                paragraphAccumulator.removeAll()
            }
        }
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            if trimmed.hasPrefix("```") {
                if inCodeBlock {
                    // Closing code block
                    blocks.append(.codeBlock(code: codeAccumulator.joined(separator: "\n"), language: codeLang))
                    codeAccumulator.removeAll()
                    codeLang = nil
                    inCodeBlock = false
                } else {
                    // Opening code block
                    flushParagraph()
                    inCodeBlock = true
                    let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    codeLang = lang.isEmpty ? nil : lang
                }
                continue
            }
            
            if inCodeBlock {
                codeAccumulator.append(line)
                continue
            }
            
            if trimmed.hasPrefix("### ") {
                flushParagraph()
                blocks.append(.header(text: String(trimmed.dropFirst(4)), level: 3))
            } else if trimmed.hasPrefix("## ") {
                flushParagraph()
                blocks.append(.header(text: String(trimmed.dropFirst(3)), level: 2))
            } else if trimmed.hasPrefix("# ") {
                flushParagraph()
                blocks.append(.header(text: String(trimmed.dropFirst(2)), level: 1))
            } else if trimmed.hasPrefix("• ") || trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph()
                let bulletText = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                blocks.append(.bullet(text: bulletText))
            } else if trimmed.isEmpty {
                flushParagraph()
            } else {
                paragraphAccumulator.append(line)
            }
        }
        
        flushParagraph()
        
        if inCodeBlock && !codeAccumulator.isEmpty {
            blocks.append(.codeBlock(code: codeAccumulator.joined(separator: "\n"), language: codeLang))
        }
        
        return blocks
    }
}
