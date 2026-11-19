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
}

/// 基于系统 Translation 框架的实现。
/// 会话由视图层 .translationTask(source:target:) 注入，
/// 由 SwiftUI 自动等待语言包就绪，无需手动处理下载。
@MainActor
final class TranslationService: TextTranslating {

    private struct LanguagePair: Equatable {
        let source: Locale.Language
        let target: Locale.Language
    }

    private struct PendingItem {
        let id: UUID
        let text: String
        let continuation: CheckedContinuation<String?, Never>
    }

    private var session: TranslationSession?
    private var requestedPair: LanguagePair?
    private var attachedPair: LanguagePair?
    private var pendingItems: [PendingItem] = []
    private var waitTimeouts: [UUID: Task<Void, Never>] = [:]
    private var isProcessing = false

    func setLanguagePair(source: Locale.Language, target: Locale.Language) async {
        let pair = LanguagePair(source: source, target: target)
        guard requestedPair != pair else { return }
        requestedPair = pair
        // 相同语言对继续复用现有会话；只有真正切换语言时才等待新会话。
        if let attachedPair, attachedPair != pair {
            session?.cancel()
            session = nil
            self.attachedPair = nil
            for item in pendingItems {
                scheduleWaitTimeout(for: item.id)
            }
        }
    }

    func attach(session: TranslationSession) {
        let pair = LanguagePair(
            source: session.sourceLanguage ?? requestedPair?.source ?? Locale.Language(identifier: "en"),
            target: session.targetLanguage ?? requestedPair?.target ?? Locale.Language(identifier: "en")
        )
        if let attachedPair, attachedPair != pair {
            self.session?.cancel()
        }
        self.session = session
        attachedPair = pair
        requestedPair = pair
        processNextIfIdle()
    }

    func translate(_ text: String) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return await withCheckedContinuation { continuation in
            let id = UUID()
            pendingItems.append(PendingItem(id: id, text: trimmed, continuation: continuation))
            scheduleWaitTimeout(for: id)
            processNextIfIdle()
        }
    }

    /// 翻译会话由 SwiftUI 在视图出现后异步注入；首次识别往往早于注入完成，
    /// 因此先排队等待会话，而不是立即判定翻译失败。
    private func scheduleWaitTimeout(for id: UUID) {
        guard session == nil else { return }
        waitTimeouts[id]?.cancel()
        waitTimeouts[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled else { return }
            self?.expireWaitingItem(id)
        }
    }

    private func expireWaitingItem(_ id: UUID) {
        waitTimeouts.removeValue(forKey: id)
        guard let index = pendingItems.firstIndex(where: { $0.id == id }) else { return }
        let item = pendingItems.remove(at: index)
        item.continuation.resume(returning: nil)
    }

    /// 串行处理队列，保证译文回填顺序与原文顺序一致
    private func processNextIfIdle() {
        guard !isProcessing, session != nil, !pendingItems.isEmpty else { return }
        isProcessing = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isProcessing = false }
            while !self.pendingItems.isEmpty {
                let item = self.pendingItems.removeFirst()
                self.waitTimeouts.removeValue(forKey: item.id)?.cancel()
                guard let session = self.session else {
                    // 会话在排队期间失效：放回队首，等待 translationTask 重新注入。
                    self.pendingItems.insert(item, at: 0)
                    self.scheduleWaitTimeout(for: item.id)
                    break
                }
                do {
                    let translated = try await self.performTranslation(item.text, using: session)
                    item.continuation.resume(returning: translated)
                } catch {
                    item.continuation.resume(returning: nil)
                }
            }
        }
    }

    /// 系统翻译偶发 internalError，短暂等待后自动再试一次；用户取消或语言包缺失不重试。
    private func performTranslation(_ text: String, using session: TranslationSession) async throws -> String {
        do {
            return try await session.translate(text).targetText
        } catch {
            guard isRetryable(error) else { throw error }
            try await Task.sleep(nanoseconds: 300_000_000)
            return try await session.translate(text).targetText
        }
    }

    private func isRetryable(_ error: Error) -> Bool {
        switch error {
        case TranslationError.internalError:
            return true
        default:
            return false
        }
    }
}
