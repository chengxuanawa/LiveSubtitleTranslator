import Foundation
import SwiftUI
import Translation

extension LiveSessionViewModel {
    func clearSegments() {
        resetPendingBuffer()
        segments = []
        failedTranslationIDs.removeAll()
        resetPartialPreview()
        sessionStart = Date()
    }

    /// 字幕气泡入场动画已播放，写回标记避免列表复用或滚动复现时重播
    func markSegmentAnimated(_ segmentID: UUID) {
        guard let index = segments.firstIndex(where: { $0.id == segmentID }),
              !segments[index].hasAnimated else { return }
        segments[index].hasAnimated = true
    }

    /// AI 润色结果回填到对应字幕片段
    func applyPolishedText(_ text: String, to segmentID: UUID, in recordingID: UUID) {
        if sessionID == recordingID, let index = segments.firstIndex(where: { $0.id == segmentID }) {
            segments[index].polishedText = text
        }
        transcriptStore.updateSegment(segmentID, in: recordingID) { $0.polishedText = text }
    }

    /// 接入 SwiftUI translationTask 提供的系统翻译会话
    /// 保持 translationTask 的 action 存活：TranslationSession 只在 action 执行期间有效，
    /// 提前返回后再用旧 session 翻译属于未定义行为，可能出现闪退。
    func keepTranslationSessionAlive(_ session: TranslationSession) async {
        let token = translationService.attach(session: session)
        defer { translationService.detach(token: token) }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// 以约 12Hz 的频率发布部分识别结果，避免高频刷新造成文字抖动；尾部补发保证文本不丢失
    func publishPartialText(_ text: String) {
        latestPartialText = text
        let now = Date()
        let elapsed = now.timeIntervalSince(lastPartialPublish)
        if elapsed >= 0.08 {
            lastPartialPublish = now
            livePartialText = text
            pushPartialUpdate(text)
            return
        }
        partialThrottleTask?.cancel()
        let delay = UInt64((0.08 - elapsed) * 1_000_000_000)
        partialThrottleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self, !self.latestPartialText.isEmpty else { return }
            self.lastPartialPublish = Date()
            self.livePartialText = self.latestPartialText
            self.pushPartialUpdate(self.latestPartialText)
        }
    }

    /// 清空实时预览并取消未执行的节流补发
    func resetPartialPreview() {
        partialThrottleTask?.cancel()
        partialThrottleTask = nil
        latestPartialText = ""
        livePartialText = ""
    }

    func handleFinalSegment(_ text: String, startTime: TimeInterval) {
        // 一句结束：先清空实时预览；有 AI 时先进入缓冲，停顿后整理成完整句子
        resetPartialPreview()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 暂停时落下已识别的尾句，实时气泡继续保持暂停提示。
        guard !isRecognitionPaused, aiService.isAvailable else {
            appendCommittedSegment(trimmed, startTime: startTime)
            return
        }

        pendingChunks.append(PendingSpeechChunk(text: trimmed, startTime: startTime))
        pendingText = pendingChunks.map(\.text).joined()
        updateVisuals(original: trimmed, translated: nil)
        schedulePendingSegmentation()
    }

    /// 把最终确定的句子落库，并异步回填译文
    private func appendCommittedSegment(_ text: String, startTime: TimeInterval) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let segment = CaptionSegment(originalText: trimmed, startTime: startTime)
        // 新卡片从下方浮入，避免落库瞬间整段文字“闪现”到列表上方
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            segments.append(segment)
        }
        recentSegmentContext.append(trimmed)
        if recentSegmentContext.count > 3 {
            recentSegmentContext.removeFirst(recentSegmentContext.count - 3)
        }
        updateVisuals(original: trimmed, translated: nil)
        requestTranslation(for: segment)
    }

    // MARK: - AI 分段

    /// 还在等断句时合并新文本，送出请求后只在取消或收尾时作废。
    private func schedulePendingSegmentation() {
        guard !pendingChunks.isEmpty, !isSegmentingPending else { return }
        guard aiService.isAvailable else {
            flushPendingBuffer()
            return
        }

        segmentationTask?.cancel()
        let force = pendingText.count >= 120 || pendingChunks.count >= 4
        let endsWithSentenceMark = pendingText.last.map { "。！？!?…".contains($0) } ?? false
        let delay: Duration = endsWithSentenceMark ? .milliseconds(300) : .milliseconds(800)
        segmentationTask = Task { [weak self] in
            if !force { try? await Task.sleep(for: delay) }
            guard let self, !Task.isCancelled else { return }
            await self.segmentAndCommitPending()
        }
    }

    private func segmentAndCommitPending() async {
        isSegmentingPending = true
        let chunks = pendingChunks
        let original = chunks.map(\.text).joined()
        let context = recentSegmentContext.isEmpty ? nil : recentSegmentContext.joined(separator: "\n")
        let sentences = await aiService.segmentSentences(original, context: context)
        guard !Task.isCancelled else { return }
        segmentationTask = nil
        isSegmentingPending = false

        pendingChunks.removeFirst(chunks.count)
        pendingText = pendingChunks.map(\.text).joined()
        commitSentences(sentences ?? Self.fallbackSegments(for: original), from: chunks)
        schedulePendingSegmentation()
    }

    /// 停止或暂停时直接按标点落库，避免等待 AI 导致字幕丢失。
    func flushPendingBuffer() {
        let chunks = takePendingChunks()
        guard !chunks.isEmpty else { return }
        commitSentences(Self.fallbackSegments(for: chunks.map(\.text).joined()), from: chunks)
    }

    func resetPendingBuffer() {
        _ = takePendingChunks()
        recentSegmentContext.removeAll()
    }

    private func takePendingChunks() -> [PendingSpeechChunk] {
        segmentationTask?.cancel()
        segmentationTask = nil
        isSegmentingPending = false
        let chunks = pendingChunks
        pendingChunks.removeAll()
        pendingText = ""
        return chunks
    }

    private func commitSentences(_ sentences: [String], from chunks: [PendingSpeechChunk]) {
        let times = startTimes(for: sentences, chunks: chunks)
        for (index, sentence) in sentences.enumerated() {
            appendCommittedSegment(sentence, startTime: times[index])
        }
    }

    /// AI 不可用或返回无效内容时，用本地标点做兜底切分
    private static func fallbackSegments(for text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if "。！？!?\n".contains(character) {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result.isEmpty ? [text] : result
    }

    /// 根据句子在原文中的位置，映射到所属识别片段的起始时间
    private func startTimes(for sentences: [String], chunks: [PendingSpeechChunk]) -> [TimeInterval] {
        let original = chunks.map(\.text).joined()
        var searchStart = original.startIndex
        var times: [TimeInterval] = []
        for sentence in sentences {
            if searchStart < original.endIndex,
               let range = original.range(of: sentence, range: searchStart..<original.endIndex) {
                let offset = original.distance(from: original.startIndex, to: range.lowerBound)
                times.append(startTime(at: offset, in: chunks))
                searchStart = range.upperBound
            } else {
                times.append(chunks.first?.startTime ?? 0)
            }
        }
        return times
    }

    private func startTime(at offset: Int, in chunks: [PendingSpeechChunk]) -> TimeInterval {
        var cumulative = 0
        for chunk in chunks {
            let length = chunk.text.count
            if offset < cumulative + length {
                return chunk.startTime
            }
            cumulative += length
        }
        return chunks.last?.startTime ?? 0
    }

    func retryTranslation(for segment: CaptionSegment) {
        guard segments.contains(where: { $0.id == segment.id }) else { return }
        requestTranslation(for: segment)
    }

    /// 自动翻译和手动重试走同一路径，只把结果回填到原有会话和字幕。
    private func requestTranslation(for segment: CaptionSegment) {
        let segmentID = segment.id
        guard settings.realtimeTranslationEnabled, translationIDsInFlight.insert(segmentID).inserted else { return }
        failedTranslationIDs.remove(segmentID)

        let recordingID = sessionID
        let pair = TranslationLanguagePair(
            source: Locale.Language(identifier: sourceIdentifier),
            target: Locale.Language(identifier: targetIdentifier)
        )
        Task { [weak self] in
            guard let self else { return }
            defer { self.translationIDsInFlight.remove(segmentID) }
            let result = await self.translationService.translate(segment.originalText, for: pair)
            self.applyTranslation(result, to: segment, in: recordingID)
        }
    }

    private func applyTranslation(_ text: String?, to segment: CaptionSegment, in recordingID: UUID) {
        let index = sessionID == recordingID ? segments.firstIndex(where: { $0.id == segment.id }) : nil
        guard let text, !text.isEmpty else {
            if index != nil { failedTranslationIDs.insert(segment.id) }
            return
        }
        if let index {
            segments[index].translatedText = text
            failedTranslationIDs.remove(segment.id)
            if index == segments.count - 1, liveDisplayText.isEmpty {
                updateVisuals(original: segment.originalText, translated: text)
            }
        }
        transcriptStore.updateSegment(segment.id, in: recordingID) { $0.translatedText = text }
    }
}
