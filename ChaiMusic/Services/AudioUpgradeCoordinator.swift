import Foundation
import AVFoundation

struct RecordingMatch {
    /// 新音源的媒體時間 = 舊音源媒體時間 + offset。
    var offset: Double
    var gain: Float
    var correlation: Double
}

enum UpgradeError: LocalizedError {
    case recordingMismatch, durationMismatch, insufficientAudio, weakMatch, alignment, timeout, cancelled, noImprovement
    var errorDescription: String? {
        switch self {
        case .recordingMismatch: return "錄音版本識別不同，保留原音源。"
        case .durationMismatch: return "兩個版本的長度差異過大，保留原音源。"
        case .insufficientAudio: return "音訊太短、靜音或解碼器無法提供可比對樣本，保留原音源。"
        case .weakMatch: return "聲學指紋未達安全門檻，可能是不同錄音或母帶。"
        case .alignment: return "播放時鐘無法安全對齊，保留原音源。"
        case .timeout: return "候選緩衝逾時，原音源繼續播放。"
        case .cancelled: return "已取消升級，保留原音源。"
        case .noImprovement: return "解碼後的真實音質未比目前來源更高。"
        }
    }
}

/// 在非主執行緒解碼三段 PCM。寧可拒絕不確定候選，也不把同名歌曲當同錄音。
actor AudioUpgradeCoordinator {
    func match(original: PreparedAudio, candidate: PreparedAudio) throws -> RecordingMatch {
        try Task.checkCancellation()
        if let lhs = original.recordingID, let rhs = candidate.recordingID, lhs != rhs {
            throw UpgradeError.recordingMismatch
        }
        guard original.duration >= 4, candidate.duration >= 4,
              abs(original.duration - candidate.duration) <= 0.12 else { throw UpgradeError.durationMismatch }
        let oldFile = try AVAudioFile(forReading: original.url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let newFile = try AVAudioFile(forReading: candidate.url, commonFormat: .pcmFormatFloat32, interleaved: false)
        var offsets: [Double] = []
        var gains: [Double] = []
        var scores: [Double] = []
        for fraction in [0.2, 0.5, 0.8] {
            try Task.checkCancellation()
            let time = min(original.duration - 1.3, max(0.2, original.duration * fraction))
            let old = try samples(file: oldFile, at: time, seconds: 0.8)
            let new = try samples(file: newFile, at: time - 0.08, seconds: 0.96)
            let count = min(old.count, 6_400)
            guard count > 4_000, new.count >= count + 1_280 else { throw UpgradeError.insufficientAudio }
            let reference = Array(old.prefix(count))
            let refEnergy = reference.reduce(0) { $0 + $1 * $1 }
            guard refEnergy / Double(count) > 0.000_001 else { throw UpgradeError.insufficientAudio }
            var best = -1.0
            var bestStart = 0
            var bestEnergy = 0.0
            // 8 kHz 探針；±80 ms 搜尋，粗搜後以單樣本精修。
            func evaluate(_ start: Int) -> (Double, Double) {
                var dot = 0.0, energy = 0.0
                for i in stride(from: 0, to: count, by: 2) {
                    let value = new[start + i]
                    dot += reference[i] * value
                    energy += value * value
                }
                let referenceEnergy = stride(from: 0, to: count, by: 2).reduce(0.0) { $0 + reference[$1] * reference[$1] }
                return (dot / max(1e-12, sqrt(referenceEnergy * energy)), energy * 2)
            }
            for start in stride(from: 0, through: 1_280, by: 8) {
                let score = evaluate(start)
                if score.0 > best { best = score.0; bestStart = start; bestEnergy = score.1 }
            }
            let coarse = bestStart
            for start in max(0, coarse - 8)...min(1_280, coarse + 8) {
                let score = evaluate(start)
                if score.0 > best { best = score.0; bestStart = start; bestEnergy = score.1 }
            }
            guard best >= 0.94 else { throw UpgradeError.weakMatch }
            offsets.append(Double(bestStart) / 8_000 - 0.08)
            gains.append(sqrt(refEnergy / max(bestEnergy, 1e-12)))
            scores.append(best)
        }
        guard let low = offsets.min(), let high = offsets.max(), high - low <= 0.003 else { throw UpgradeError.alignment }
        let gain = gains.reduce(0, +) / Double(gains.count)
        guard gain >= 0.5, gain <= 2 else { throw UpgradeError.weakMatch }
        // AVPlayer 音量只作衰減；不宣稱位元完美或母帶等價。
        return RecordingMatch(offset: offsets.reduce(0, +) / Double(offsets.count),
                              gain: Float(min(1, gain)), correlation: scores.min() ?? 0)
    }

    private func samples(file: AVAudioFile, at seconds: Double, seconds length: Double) throws -> [Double] {
        let format = file.processingFormat
        guard format.sampleRate >= 8_000, format.sampleRate <= 384_000,
              format.channelCount > 0, format.channelCount <= 8 else { throw UpgradeError.insufficientAudio }
        let start = AVAudioFramePosition(max(0, seconds) * format.sampleRate)
        let frameCount = AVAudioFrameCount(length * format.sampleRate + 4)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { throw UpgradeError.insufficientAudio }
        file.framePosition = min(start, file.length)
        try file.read(into: buffer, frameCount: frameCount)
        guard let channels = buffer.floatChannelData, buffer.frameLength > 2 else { throw UpgradeError.insufficientAudio }
        let outputCount = Int((Double(buffer.frameLength) - 2) * 8_000 / format.sampleRate)
        var output = [Double](repeating: 0, count: outputCount)
        for i in output.indices {
            let position = Double(i) * format.sampleRate / 8_000
            let lower = Int(position)
            let fraction = position - Double(lower)
            var value = 0.0
            for channel in 0..<Int(format.channelCount) {
                value += Double(channels[channel][lower]) * (1 - fraction) + Double(channels[channel][lower + 1]) * fraction
            }
            output[i] = value / Double(format.channelCount)
        }
        let mean = output.reduce(0, +) / Double(max(1, output.count))
        return output.map { $0 - mean }
    }

    nonisolated static func improves(_ candidate: AudioQuality, over current: AudioQuality, preferLossless: Bool) -> Bool {
        let lossless: Set<String> = ["FLAC", "ALAC", "PCM"]
        let newer = lossless.contains(candidate.codec.uppercased())
        let older = lossless.contains(current.codec.uppercased())
        if preferLossless, newer != older { return newer }
        if newer && older {
            guard let newRate = candidate.sampleRate, let oldRate = current.sampleRate else { return false }
            if newRate > oldRate { return true }
            return newRate == oldRate && (candidate.bitDepth ?? 0) > (current.bitDepth ?? 0)
        }
        guard candidate.codec == current.codec, let newRate = candidate.bitRate, let oldRate = current.bitRate else { return false }
        return newRate > oldRate * 1.1
    }
}
