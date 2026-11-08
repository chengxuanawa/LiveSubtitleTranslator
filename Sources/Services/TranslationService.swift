import Foundation
import Translation

/// 文本翻译能力抽象，便于二次开发时替换为其他翻译引擎（如在线 API）。
@MainActor
protocol TextTranslating: AnyObject {
    /// 设定翻译语言对
    func setLanguagePair(source: Locale.Language, target: Locale.Language) async
    /// 接入由 SwiftUI translationTask 提供的系统翻译会话
    func attach(session: TranslationSession)
    /// 翻译单条文本；失败时返回 nil（界面回退为仅显示原文）
    func translate(_ text: String) async -> String?
    var onTranslationError: ((_ message: String) -> Void)? { get set }
}

/// 基于系统 Translation 框架的实现。
/// 会话由视图层 .translationTask(source:target:) 注入：
/// - 兼容 iOS 18-25（程序化构造器已随新 SDK 移除，直接 init 仅 iOS 26+ 可用）；
/// - 由 SwiftUI 自动等待语言包就绪，无需手动处理下载。
@MainActor
final class TranslationService: ObservableObject, TextTranslating {

    var onTranslationError: ((_ message: String) -> Void)?

    private var session: TranslationSession?
    private var activeSource: Locale.Language?
    private var activeTarget: Locale.Language?
    private var pendingItems: [(text: String, continuation: CheckedContinuation<String?, Never>)] = []
    private var isProcessing = false

    func setLanguagePair(source: Locale.Language, target: Locale.Language) async {
        guard activeSource != source || activeTarget != target else { return }
        activeSource = source
        activeTarget = target
        // 语言变化后 translationTask 会自动重建并重新注入新会话
        session = nil
    }

    func attach(session: TranslationSession) {
        self.session = session
    }

    func translate(_ text: String) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, session != nil else { return nil }
        return await withCheckedContinuation { continuation in
            pendingItems.append((trimmed, continuation))
            processNextIfIdle()
        }
    }

    /// 串行处理队列，保证译文回填顺序与原文顺序一致
    private func processNextIfIdle() {
        guard !isProcessing else { return }
        isProcessing = true
        Task { [weak self] in
            defer { self?.isProcessing = false }
            guard let self else { return }
            while !self.pendingItems.isEmpty {
                let item = self.pendingItems.removeFirst()
                do {
                    let response = try await self.session?.translate(item.text)
                    item.continuation.resume(returning: response?.targetText)
                } catch {
                    item.continuation.resume(returning: nil)
                    self.onTranslationError?(error.localizedDescription)
                }
            }
        }
    }
}