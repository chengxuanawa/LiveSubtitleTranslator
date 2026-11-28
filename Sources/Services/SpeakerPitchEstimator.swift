import FluidAudio
import Foundation

/// 用归一化自相关估计说话人基频，供男声/女声粗判使用。
enum SpeakerPitchEstimator {

    /// 对每个说话人时间片逐帧估计基频，返回 speakerId -> 基频样本（Hz）
    static func pitchBySpeaker(
        chunk: [Float],
        segments: [TimedSpeakerSegment],
        chunkStart: TimeInterval
    ) -> [String: [Double]] {
        let sampleRate = 16_000.0
        let frameSize = 640  // 40ms
        let hopSize = 480  // 30ms
        let maxFramesPerSpeaker = 16
        var result: [String: [Double]] = [:]
        for segment in segments where !segment.speakerId.isEmpty {
            let start = Int((Double(segment.startTimeSeconds) - chunkStart) * sampleRate)
            let end = Int((Double(segment.endTimeSeconds) - chunkStart) * sampleRate)
            let lower = max(0, start)
            let upper = min(chunk.count, end)
            guard upper - lower >= frameSize else { continue }
            var frequencies: [Double] = []
            var cursor = lower
            while cursor + frameSize <= upper, frequencies.count < maxFramesPerSpeaker {
                if let frequency = pitch(
                    in: chunk,
                    start: cursor,
                    count: frameSize,
                    sampleRate: sampleRate
                ) {
                    frequencies.append(frequency)
                }
                cursor += hopSize
            }
            if !frequencies.isEmpty {
                result[segment.speakerId, default: []].append(contentsOf: frequencies)
            }
        }
        return result
    }

    /// 单帧基频：YIN 累积均值归一化差分，减少倍频/半频误判
    private static func pitch(
        in samples: [Float],
        start: Int,
        count: Int,
        sampleRate: Double
    ) -> Double? {
        var mean: Float = 0
        for index in 0..<count {
            mean += samples[start + index]
        }
        mean /= Float(count)

        var centered = [Float](repeating: 0, count: count)
        var prefix = [Float](repeating: 0, count: count + 1)
        for index in 0..<count {
            let value = samples[start + index] - mean
            centered[index] = value
            prefix[index + 1] = prefix[index] + value * value
        }
        // 低于约 -40 dBFS 视为静音，不参与性别判断
        guard prefix[count] / Float(count) > 0.0001 else { return nil }

        let minLag = max(2, Int(sampleRate / 300.0))
        let maxLag = min(count - 2, Int(sampleRate / 70.0))
        guard maxLag > minLag + 1 else { return nil }

        // 差分函数 d(tau) = 两段能量和 - 2 * 互相关
        var difference = [Float](repeating: 0, count: maxLag + 2)
        for tau in 1...maxLag {
            var correlation: Float = 0
            let limit = count - tau
            for index in 0..<limit {
                correlation += centered[index] * centered[index + tau]
            }
            let startEnergy = prefix[limit]
            let shiftedEnergy = prefix[count] - prefix[tau]
            difference[tau] = max(0, startEnergy + shiftedEnergy - 2 * correlation)
        }

        // 累积均值归一化，抵消高延迟处的能量下降
        var normalized = [Float](repeating: 1, count: maxLag + 2)
        var runningSum: Float = 0
        for tau in 1...maxLag {
            runningSum += difference[tau]
            normalized[tau] =
                runningSum > 0 ? difference[tau] * Float(tau) / runningSum : 1
        }

        // 第一个低于阈值的局部最小值即基音周期
        let threshold: Float = 0.15
        var chosenLag = 0
        for tau in (minLag + 1)...maxLag {
            guard normalized[tau] < threshold else { continue }
            if normalized[tau] <= normalized[tau - 1],
               normalized[tau] <= normalized[tau + 1] {
                chosenLag = tau
                break
            }
        }
        if chosenLag == 0 {
            chosenLag = (minLag...maxLag).min(by: { normalized[$0] < normalized[$1] }) ?? 0
            guard chosenLag > 0, normalized[chosenLag] <= 0.35 else { return nil }
        }
        let frequency = sampleRate / Double(chosenLag)
        return (70...300).contains(frequency) ? frequency : nil
    }
}
