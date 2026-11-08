import Foundation
import Translation

/// 文本翻译能力抽象，便于二次开发时替换为其他翻译引擎（如在线 API）。
@MainActor
protocol TextTranslating: AnyObject {
    /// 设定翻译语言对（内部建立会话）
    func setLanguagePair(source: Locale.Language, target: Locale.Language) async
    /// 翻译单条文本；失败时返回 nil（界面回退为仅显示原文）
    func translate(_ text: String) async -> String?
    var onTranslationError: ((_ message: String) -> Void)? { get set }
}

/// 基于系统 Translation 框架的实现（iOS 18+）。
/// 系统默认“灵活模式”：优先使用设备端语言模型，缺失时回退服务器。
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
        session?.invalidate()
        session = nil
        do {
            session = try await TranslationSession(sourceLanguage: source, targetLanguage: target)
        } catch {
            onTranslationError?("翻译服务初始化失败：\(error.localizedDescription)")
        }
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
                    let responses = try await self.session?.translations(from: [item.text])
                    item.continuation.resume(returning: responses?.first?.targetText)
                } catch {
                    item.continuation.resume(returning: nil)
                    self.onTranslationError?(error.localizedDescription)
                }
            }
        }
    }
}