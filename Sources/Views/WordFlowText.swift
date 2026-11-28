import NaturalLanguage
import SwiftUI

/// 把句子拆成可点击单词的文本视图：单击查词，横向滑动可选中一组单词并翻译
struct WordFlowText: View {
    let text: String
    let font: Font
    var color: Color = .primary
    /// 入场渐显进度（0 = 模糊透明，1 = 清晰）
    var blurProgress: Double = 1
    var onWordTap: (String) -> Void
    /// 横向滑选单词组合时回调；未提供时复用 onWordTap
    var onPhraseSelect: ((String) -> Void)? = nil

    @State private var wordFrames: [Int: CGRect] = [:]
    @State private var selection: ClosedRange<Int>?
    @State private var selectionAnchor: Int?
    @State private var isSelecting = false

    private let coordinateSpace = "wordFlow"

    var body: some View {
        let pieces = WordTokenizer.pieces(in: text)
        FlowLayout(spacing: 0, lineSpacing: 2) {
            ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                if let word = piece.word, let wordIndex = piece.wordIndex {
                    Text(piece.text)
                        .font(font)
                        .foregroundStyle(color)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.accentColor.opacity(isSelected(wordIndex) ? 0.22 : 0))
                                .padding(.horizontal, -2)
                                .padding(.vertical, -1)
                        )
                        .contentShape(Rectangle())
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: WordFramePreferenceKey.self,
                                    value: [wordIndex: proxy.frame(in: .named(coordinateSpace))]
                                )
                            }
                        )
                        .onTapGesture { onWordTap(word) }
                } else {
                    Text(piece.text)
                        .font(font)
                        .foregroundStyle(color)
                }
            }
        }
        .coordinateSpace(name: coordinateSpace)
        .onPreferenceChange(WordFramePreferenceKey.self) { wordFrames = $0 }
        .simultaneousGesture(selectionGesture(pieces: pieces))
        .opacity(min(1, max(0.08, blurProgress)))
        .blur(radius: CGFloat(max(0, (1 - blurProgress) * 3)))
    }

    private func isSelected(_ index: Int) -> Bool {
        selection?.contains(index) ?? false
    }

    /// 横向拖动时按经过的单词连成一段选区；纵向拖动交给外层滚动
    private func selectionGesture(pieces: [WordPiece]) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(coordinateSpace))
            .onChanged { value in
                let horizontal = abs(value.translation.width)
                let vertical = abs(value.translation.height)
                if !isSelecting {
                    guard horizontal > 10, horizontal > vertical * 1.3 else { return }
                    guard let anchor = wordIndex(at: value.startLocation) else { return }
                    selectionAnchor = anchor
                    selection = anchor...anchor
                    isSelecting = true
                }
                guard let anchor = selectionAnchor,
                      let current = wordIndex(at: value.location) else { return }
                selection = min(anchor, current)...max(anchor, current)
            }
            .onEnded { _ in
                defer {
                    isSelecting = false
                    selectionAnchor = nil
                    selection = nil
                }
                guard isSelecting, let range = selection,
                      range.lowerBound != range.upperBound else { return }
                // 直接拼接所选片段的原文，中文等无空格语言不会被强行加空格
                let phrase = pieces
                    .filter { piece in
                        guard let index = piece.wordIndex else { return false }
                        return range.contains(index)
                    }
                    .map(\.text)
                    .joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !phrase.isEmpty else { return }
                if let onPhraseSelect {
                    onPhraseSelect(phrase)
                } else {
                    onWordTap(phrase)
                }
            }
    }

    /// 找到坐标所在的单词；落在词间空隙或跨行时取最近的一个
    private func wordIndex(at point: CGPoint) -> Int? {
        if let hit = wordFrames.first(where: { $0.value.contains(point) })?.key {
            return hit
        }
        let sameLine = wordFrames.filter {
            point.y >= $0.value.minY && point.y <= $0.value.maxY
        }
        if let nearest = sameLine.min(by: {
            abs($0.value.midX - point.x) < abs($1.value.midX - point.x)
        }) {
            return nearest.key
        }
        return wordFrames.min(by: {
            hypot($0.value.midX - point.x, $0.value.midY - point.y)
                < hypot($1.value.midX - point.x, $1.value.midY - point.y)
        })?.key
    }
}

/// 记录每个单词在文本坐标系中的位置，用于滑选命中
private struct WordFramePreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - 分词

private struct WordPiece {
    var text: String
    var word: String?
    /// 单词序号（不含空格 / 标点），用于滑选范围
    var wordIndex: Int?
}

private enum WordTokenizer {
    /// 用 NaturalLanguage 分词；单词之间的空格、标点跟随前一个词，避免换行时行首出现空隙
    static func pieces(in text: String) -> [WordPiece] {
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var pieces: [WordPiece] = []
        var cursor = text.startIndex
        var nextWordIndex = 0

        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let gap = String(text[cursor..<range.lowerBound])
            if !gap.isEmpty {
                if pieces.indices.contains(pieces.count - 1) {
                    pieces[pieces.count - 1].text += gap
                } else {
                    pieces.append(WordPiece(text: gap, word: nil, wordIndex: nil))
                }
            }
            let token = String(text[range])
            let isWord = token.rangeOfCharacter(from: .letters) != nil
            pieces.append(
                WordPiece(
                    text: token,
                    word: isWord ? token : nil,
                    wordIndex: isWord ? nextWordIndex : nil
                )
            )
            if isWord { nextWordIndex += 1 }
            cursor = range.upperBound
            return true
        }

        if cursor < text.endIndex {
            let tail = String(text[cursor...])
            if !tail.isEmpty {
                if pieces.indices.contains(pieces.count - 1) {
                    pieces[pieces.count - 1].text += tail
                } else {
                    pieces.append(WordPiece(text: tail, word: nil, wordIndex: nil))
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
