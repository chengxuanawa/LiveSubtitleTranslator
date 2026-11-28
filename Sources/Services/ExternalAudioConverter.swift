import AVFoundation
import Foundation

/// 串行后台队列上的外部音频转换器
final class ExternalAudioConverter {
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let input = buffer.format
        if input == format { return buffer }
        if converter == nil || inputFormat != input || outputFormat != format {
            converter = AVAudioConverter(from: input, to: format)
            inputFormat = input
            outputFormat = format
        }
        guard let converter else { return nil }
        return convertSpeechPCM(buffer, using: converter, to: format)
    }
}

/// 将音频缓冲转换为识别引擎要求的格式
func convertSpeechPCM(
    _ buffer: AVAudioPCMBuffer,
    using converter: AVAudioConverter,
    to format: AVAudioFormat
) -> AVAudioPCMBuffer? {
    let ratio = format.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
    guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

    var supplied = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
        if supplied {
            status.pointee = .noDataNow
            return nil
        }
        supplied = true
        status.pointee = .haveData
        return buffer
    }
    guard error == nil, output.frameLength > 0 else { return nil }
    return output
}
