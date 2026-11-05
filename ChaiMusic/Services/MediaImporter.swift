import Foundation
import AVFoundation
import AudioToolbox

struct ImportResult {
    var tracks: [Track] = []
    var failures: [String] = []
}

actor MediaImporter {
    let root: URL
    init(root: URL) { self.root = root }

    func importAudio(urls: [URL]) async -> ImportResult {
        var result = ImportResult()
        let fm = FileManager.default
        let audio = root.appendingPathComponent("Audio", isDirectory: true)
        let artwork = root.appendingPathComponent("Artwork", isDirectory: true)
        do {
            try fm.createDirectory(at: audio, withIntermediateDirectories: true)
            try fm.createDirectory(at: artwork, withIntermediateDirectories: true)
        } catch {
            result.failures.append("無法建立音樂資料夾，請確認裝置儲存空間。")
            return result
        }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let id = UUID()
            let ext = url.pathExtension.lowercased()
            guard ["m4a", "mp3", "aac", "wav", "aiff", "aif", "caf", "flac", "mp4"].contains(ext) else {
                result.failures.append("\(url.lastPathComponent)：不支援此音檔格式。")
                continue
            }
            let fileName = "\(id.uuidString).\(ext)"
            let destination = audio.appendingPathComponent(fileName)
            do {
                try fm.copyItem(at: url, to: destination)
                let asset = AVURLAsset(url: destination)
                let playable = try await asset.load(.isPlayable)
                let protected = try await asset.load(.hasProtectedContent)
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                guard playable, !protected, let stream = audioTracks.first else {
                    throw ImportError.unplayable
                }
                let duration = try await asset.load(.duration).seconds
                guard duration.isFinite, duration > 0 else { throw ImportError.unplayable }
                var track = Track(id: id, title: url.deletingPathExtension().lastPathComponent, fileName: fileName)
                track.duration = duration
                track.quality.container = ext.uppercased()
                if let rate = try? await stream.load(.estimatedDataRate), rate > 0 {
                    track.quality.bitRate = Double(rate)
                }
                if let descriptions = try? await stream.load(.formatDescriptions), let description = descriptions.first,
                   let pointer = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
                    let asbd = pointer.pointee
                    track.quality.sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : nil
                    track.quality.bitDepth = asbd.mBitsPerChannel > 0 ? Int(asbd.mBitsPerChannel) : nil
                    track.quality.codec = Self.codecName(asbd.mFormatID)
                }
                if let metadata = try? await asset.load(.commonMetadata) {
                    for item in metadata {
                        switch item.commonKey {
                        case .commonKeyTitle:
                            if let value = try? await item.load(.stringValue), !value.isEmpty { track.title = value }
                        case .commonKeyArtist:
                            if let value = try? await item.load(.stringValue), !value.isEmpty { track.artist = value }
                        case .commonKeyAlbumName:
                            if let value = try? await item.load(.stringValue), !value.isEmpty { track.album = value }
                        case .commonKeyArtwork:
                            if let data = try? await item.load(.dataValue), data.count < 20_000_000 {
                                let name = "\(id.uuidString).image"
                                try data.write(to: artwork.appendingPathComponent(name), options: .atomic)
                                track.artworkName = name
                            }
                        default: break
                        }
                    }
                }
                result.tracks.append(track)
            } catch {
                try? fm.removeItem(at: destination)
                result.failures.append("\(url.lastPathComponent)：匯入失敗，請確認檔案可讀、格式受系統支援且沒有 DRM 保護。")
            }
        }
        return result
    }

    private enum ImportError: Error { case unplayable }
    private static func codecName(_ code: AudioFormatID) -> String {
        switch code {
        case kAudioFormatMPEG4AAC: return "AAC"
        case kAudioFormatMPEG4AAC_HE: return "HE-AAC"
        case kAudioFormatMPEG4AAC_HE_V2: return "HE-AAC v2"
        case kAudioFormatMPEGLayer3: return "MP3"
        case kAudioFormatAppleLossless: return "ALAC"
        case kAudioFormatFLAC: return "FLAC"
        case kAudioFormatLinearPCM: return "PCM"
        default: return "未知"
        }
    }
}
