import NaturalLanguage
import SwiftUI

/// 把句子拆成可点击单词的文本视图：保留原有换行行为，单击单词回调
struct WordFlowText: View {
    let text: String
    let font: Font
    var color: Color = .primary
    /// 入场渐显进度（0 = 模糊透明，1 = 清晰）
    var blurProgress: Double = 1
    var onWordTap: (String) -> Void

    var body: some View {
        let pieces = WordTokenizer.pieces(in: text)
        FlowLayout(spacing: 0, lineSpacing: 2) {
            ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                if let word = piece.word {
                    Text(piece.text)
                        .font(font)
                        .foregroundStyle(color)
                        .contentShape(Rectangle())
                        .onTapGesture { onWordTap(word) }
                } else {
                    Text(piece.text)
                        .font(font)
                        .foregroundStyle(color)
                }
            }
        }
        .opacity(min(1, max(0.08, blurProgress)))
        .blur(radius: CGFloat(max(0, (1 - blurProgress) * 3)))
    }
}

// MARK: - 分词

private struct WordPiece {
    var text: String
    var word: String?
}

private enum WordTokenizer {
    /// 用 NaturalLanguage 分词；单词之间的空格、标点跟随前一个词，避免换行时行首出现空隙
    static func pieces(in text: String) -> [WordPiece] {
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var pieces: [WordPiece] = []
        var cursor = text.startIndex

        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let gap = String(text[cursor..<range.lowerBound])
            if !gap.isEmpty {
                if pieces.indices.contains(pieces.count - 1) {
                    pieces[pieces.count - 1].text += gap
                } else {
                    pieces.append(WordPiece(text: gap, word: nil))
                }
            }
            let token = String(text[range])
            let isWord = token.rangeOfCharacter(from: .letters) != nil
            pieces.append(WordPiece(text: token, word: isWord ? token : nil))
            cursor = range.upperBound
            return true
        }

        if cursor < text.endIndex {
            let tail = String(text[cursor...])
            if !tail.isEmpty {
                if pieces.indices.contains(pieces.count - 1) {
                    pieces[pieces.count - 1].text += tail
                } else {
                    pieces.append(WordPiece(text: tail, word: nil))
                }
            }
        }
        return pieces
    }
}

// MARK: - 自动换行布局

/// 简单的横向流式布局：放不下时换行，用于逐词排列
struct FlowLayout: Layout {
    var spacing: CGFloat = 0
    var lineSpacing: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            usedWidth = max(usedWidth, x)
            lineHeight = max(lineHeight, size.height)
        }
        let width = maxWidth.isFinite ? maxWidth : usedWidth
        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
