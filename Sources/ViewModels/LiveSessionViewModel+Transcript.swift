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
    func applyPolishedText(_ text: String, to segmentID: UUID) {
        guard let index = segments.firstIndex(where: { $0.id == segmentID }) else { return }
        segments[index].polishedText = text
        if state == .ended {
            saveCurrentSession()
        }
    }

    /// 接入 SwiftUI translationTask 提供的系统翻译会话
    /// 保持 translationTask 的 action 存活：TranslationSession 只在 action 执行期间有效，
    /// 提前返回后再用旧 session 翻译属于未定义行为，可能出现闪退。
    func keepTranslationSessionAlive(_ session: TranslationSession) async {
        let token = translationService.attach(session: session)
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        translationService.detach(token: token)
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

        // AI 不可用时保持原来的即时落库
        guard aiService.isAvailable else {
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
        let segmentID = segment.id
        updateVisuals(original: trimmed, translated: nil)

        guard settings.realtimeTranslationEnabled else { return }

        Task { [weak self] in
            guard let self else { return }
            let translated = await self.translationService.translate(trimmed)
            guard let translated, !translated.isEmpty else {
                self.failedTranslationIDs.insert(segmentID)
                return
            }
            guard let index = self.segments.firstIndex(where: { $0.id == segmentID }) else { return }
            self.segments[index].translatedText = translated
            self.failedTranslationIDs.remove(segmentID)
            self.updateVisuals(original: trimmed, translated: translated)
            // 会话结束后仍有译文回填时，刷新已保存的记录
            if self.state == .ended {
                self.saveCurrentSession()
            }
        }
    }

    // MARK: - AI 分段

    /// 停顿约 0.3 秒后交给 AI 合并/切分；缓冲过长时立即整理
    private func schedulePendingSegmentation() {
        guard !pendingChunks.isEmpty else { return }
        guard aiService.isAvailable else {
            flushPendingBuffer()
            return
        }

        segmentationRequestID += 1
        let requestID = segmentationRequestID
        let force = pendingText.count >= 120 || pendingChunks.count >= 4
        // 已经以句末标点结束时立即整理；否则多等一会儿，
        // 让后续碎片并进来，避免每句话都单独成段
        let endsWithSentenceMark = pendingText.last.map { "。！？!?…".contains($0) } ?? false
        let delay: UInt64 = endsWithSentenceMark ? 300_000_000 : 800_000_000
        segmentationTask = Task { [weak self] in
            if !force {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard let self,
                  !Task.isCancelled,
                  self.segmentationRequestID == requestID else { return }
            await self.segmentAndCommitPending()
        }
    }

    private func segmentAndCommitPending() async {
        guard !isSegmentingPending, !pendingChunks.isEmpty else { return }
        isSegmentingPending = true
        defer { isSegmentingPending = false }

        let generation = segmentationGeneration
        let chunks = pendingChunks
        let original = chunks.map(\.text).joined()
        guard !original.isEmpty else {
            pendingChunks.removeAll()
            pendingText = ""
            return
        }

        let sentences = await aiService.segmentSentences(
            original,
            context: recentSegmentContext.isEmpty ? nil : recentSegmentContext.joined(separator: "\n")
        )
        guard generation == segmentationGeneration else {
            if !pendingChunks.isEmpty {
                schedulePendingSegmentation()
            }
            return
        }

        // 只移除本次已处理的片段；AI 处理期间新到的片段继续保留
        let processedCount = min(chunks.count, pendingChunks.count)
        pendingChunks.removeFirst(processedCount)
        pendingText = pendingChunks.map(\.text).joined()

        let finalSentences = sentences ?? Self.fallbackSegments(for: original)
        let times = startTimes(for: finalSentences, chunks: chunks)
        for (index, sentence) in finalSentences.enumerated() {
            let time = times.indices.contains(index) ? times[index] : (chunks.first?.startTime ?? 0)
            appendCommittedSegment(sentence, startTime: time)
        }

        if !pendingChunks.isEmpty {
            schedulePendingSegmentation()
        }
    }

    /// 结束或清空时直接按标点兜底落库，避免 AI 未返回导致字幕丢失
    func flushPendingBuffer() {
        segmentationRequestID += 1
        segmentationGeneration = UUID()
        let chunks = pendingChunks
        pendingChunks.removeAll()
        pendingText = ""
        guard !chunks.isEmpty else { return }

        let original = chunks.map(\.text).joined()
        let sentences = Self.fallbackSegments(for: original)
        let times = startTimes(for: sentences, chunks: chunks)
        for (index, sentence) in sentences.enumerated() {
            let time = times.indices.contains(index) ? times[index] : (chunks.first?.startTime ?? 0)
            appendCommittedSegment(sentence, startTime: time)
        }
    }

    func resetPendingBuffer() {
        segmentationRequestID += 1
        segmentationGeneration = UUID()
        pendingChunks.removeAll()
        pendingText = ""
        recentSegmentContext.removeAll()
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

    /// 手动重试某一条未生成译文的字幕
    func retryTranslation(for segment: CaptionSegment) {
        guard settings.realtimeTranslationEnabled else { return }
        let segmentID = segment.id
        failedTranslationIDs.remove(segmentID)

        Task { [weak self] in
            guard let self else { return }
            let translated = await self.translationService.translate(segment.originalText)
            guard let translated, !translated.isEmpty,
                  let index = self.segments.firstIndex(where: { $0.id == segmentID }) else {
                self.failedTranslationIDs.insert(segmentID)
                return
            }
            self.segments[index].translatedText = translated
            self.failedTranslationIDs.remove(segmentID)
            // 只有最新一条需要同步到灵动岛 / 画中画
            if self.segments.last?.id == segmentID {
                self.updateVisuals(original: segment.originalText, translated: translated)
            }
            if self.state == .ended {
                self.saveCurrentSession()
            }
        }
    }
}
