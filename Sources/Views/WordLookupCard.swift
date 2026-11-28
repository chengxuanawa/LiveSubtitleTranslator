import SwiftUI

/// 单词查询请求
struct WordLookupRequest: Identifiable {
    let id = UUID()
    let word: String
    let sentence: String
}

/// 单词释义小卡片：查询中 → 释义 / 失败提示
struct WordLookupCard: View {
    let request: WordLookupRequest

    @EnvironmentObject private var aiService: AIService
    @Environment(\.dismiss) private var dismiss

    @State private var result: WordLookupResult?
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(request.word)
                    .font(.title2.weight(.bold))
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭")
            }

            if isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在查询…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if let result {
                ScrollView {
                    Text(result.definition)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                Text(result.source)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text("暂时无法获取结果。可以长按句子拷贝后用系统词典查询。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: request.id) {
            isLoading = true
            result = await WordLookupService(aiService: aiService)
                .lookup(word: request.word, sentence: request.sentence)
            isLoading = false
        }
    }
}
