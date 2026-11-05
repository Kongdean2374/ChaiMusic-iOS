import Foundation
import AVFoundation

// 在 macOS 原生 AVFoundation 執行，不能代替 iPhone 的聽感與系統音訊驗收。
@main
struct AudioIntegration {
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        func prepared(_ name: String, codec: String) async throws -> PreparedAudio {
            let url = directory.appendingPathComponent(name)
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard !tracks.isEmpty, duration > 11, duration < 13, try await asset.load(.isPlayable) else {
                throw TestError.failed("音訊未被 AVFoundation 正確解碼：\(name)")
            }
            let descriptions = try await tracks[0].load(.formatDescriptions)
            guard descriptions.first.flatMap({ CMAudioFormatDescriptionGetStreamBasicDescription($0) }) != nil else {
                throw TestError.failed("找不到真實音訊格式：\(name)")
            }
            var quality = AudioQuality()
            quality.source = "原創整合測試"
            quality.codec = codec
            quality.container = url.pathExtension.uppercased()
            quality.bitRate = Double(try await tracks[0].load(.estimatedDataRate))
            return PreparedAudio(url: url, quality: quality, duration: duration, recordingID: "chaimusic-original-fixture-2026-v2")
        }
        let low = try await prepared("low.m4a", codec: "AAC")
        let high = try await prepared("high.flac", codec: "FLAC")
        let wrong = try await prepared("different.wav", codec: "PCM")
        let matcher = AudioUpgradeCoordinator()
        let result = try await matcher.match(original: low, candidate: high)
        guard result.correlation >= 0.94, abs(result.offset) < 0.12, result.gain.isFinite else {
            throw TestError.failed("同一錄音匹配未達安全門檻")
        }
        print("同一原創錄音 AAC→FLAC 比對成功；偏差 \(result.offset) 秒，相關性 \(result.correlation)。")
        var rejectedWrongRecording = false
        do { _ = try await matcher.match(original: low, candidate: wrong) }
        catch { rejectedWrongRecording = true }
        guard rejectedWrongRecording else { throw TestError.failed("不同錄音未被拒絕") }
        print("錯版錄音已正確拒絕。這項結果不代表 iPhone crossfade 已實測。")
    }
    enum TestError: LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let message) = self { return message }; return nil }
    }
}
