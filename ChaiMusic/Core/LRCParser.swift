import Foundation

enum LRCParser {
    private static let linePattern = try! NSRegularExpression(pattern: #"\[([0-9:.]+)\]"#)
    private static let wordPattern = try! NSRegularExpression(pattern: #"<([0-9:.]+)>"#)
    private static let metadataPattern = try! NSRegularExpression(pattern: #"^\[([A-Za-z]+):(.*)\]$"#)

    // LRC 正 offset 是提早顯示；內部 offset 是相對音訊的延遲秒數。
    static func parse(_ text: String) -> Lyrics {
        var lyrics = Lyrics()
        var plain: [String] = []
        let normalized = text.replacingOccurrences(of: "\u{FEFF}", with: "")
        for raw in normalized.components(separatedBy: .newlines).prefix(20_000) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let ns = trimmed as NSString
            let range = NSRange(location: 0, length: ns.length)
            if let metadata = metadataPattern.firstMatch(in: trimmed, range: range) {
                let key = ns.substring(with: metadata.range(at: 1)).lowercased()
                let value = ns.substring(with: metadata.range(at: 2)).trimmingCharacters(in: .whitespaces)
                if key == "offset", let milliseconds = Double(value), milliseconds.isFinite, abs(milliseconds) <= 3_600_000 {
                    lyrics.offset = -milliseconds / 1000
                }
                if key == "lang" || key == "language" { lyrics.language = value }
                if key == "by", !value.isEmpty { lyrics.source = "使用者匯入 · \(value)" }
                continue
            }
            let matches = linePattern.matches(in: trimmed, range: range)
            var stamps: [(time: Double, end: Int)] = []
            var previousEnd = 0
            for match in matches {
                let gap = ns.substring(with: NSRange(location: previousEnd, length: match.range.location - previousEnd))
                guard gap.trimmingCharacters(in: .whitespaces).isEmpty,
                      let time = timestamp(ns.substring(with: match.range(at: 1))) else { break }
                stamps.append((time, NSMaxRange(match.range)))
                previousEnd = NSMaxRange(match.range)
            }
            guard let last = stamps.last else {
                if !trimmed.isEmpty { plain.append(trimmed) }
                continue
            }
            let body = ns.substring(from: last.end).trimmingCharacters(in: .whitespaces)
            let baseTime = stamps[0].time
            let parsed = words(in: body, lineTime: baseTime)
            for stamp in stamps {
                let shift = stamp.time - baseTime
                let shifted = parsed.words.map { LyricWord(time: max(0, $0.time + shift), text: $0.text) }
                lyrics.lines.append(LyricLine(time: stamp.time, text: parsed.text, words: shifted))
            }
        }
        // 同時戳保留原始順序，雙語匯入由 TranslationMapper 單獨明確對齊。
        lyrics.lines = lyrics.lines.enumerated().sorted {
            $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time
        }.map(\.element)
        if lyrics.lines.isEmpty {
            let value = plain.joined(separator: "\n")
            lyrics.staticText = value.isEmpty ? nil : value
        }
        return lyrics
    }

    static func timestamp(_ value: String) -> Double? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              let seconds = Double(parts[parts.count - 1]), seconds >= 0, seconds < 60,
              let minutes = Double(parts[parts.count - 2]), minutes >= 0, minutes.rounded() == minutes else { return nil }
        let hours: Double
        if parts.count == 3 {
            guard minutes < 60, let parsed = Double(parts[0]), parsed >= 0, parsed.rounded() == parsed else { return nil }
            hours = parsed
        } else { hours = 0 }
        let result = hours * 3600 + minutes * 60 + seconds
        return result.isFinite && result <= 86_400 ? result : nil
    }

    private static func words(in body: String, lineTime: Double) -> (text: String, words: [LyricWord]) {
        let ns = body as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = wordPattern.matches(in: body, range: range)
        guard !matches.isEmpty else { return (body, []) }
        let clean = wordPattern.stringByReplacingMatches(in: body, range: range, withTemplate: "")
        var result: [LyricWord] = []
        if let first = matches.first, first.range.location > 0 {
            result.append(LyricWord(time: lineTime, text: ns.substring(to: first.range.location)))
        }
        var previous = lineTime
        for (index, match) in matches.enumerated() {
            guard let time = timestamp(ns.substring(with: match.range(at: 1))), time >= previous, time >= lineTime else {
                return (clean, [])
            }
            let start = NSMaxRange(match.range)
            let end = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            let word = ns.substring(with: NSRange(location: start, length: end - start))
            if !word.isEmpty { result.append(LyricWord(time: time, text: word)) }
            previous = time
        }
        return (clean, result)
    }
}

// 匹配與翻譯規則不依賴 UI 或網路，可直接作首輪核心測試。
enum LyricsSelection {
    static func best(_ candidates: [Lyrics], recordingID: String?) -> Lyrics? {
        guard let recordingID, !recordingID.isEmpty else { return nil }
        return candidates.filter {
            $0.recordingID == recordingID && (!$0.lines.isEmpty || !($0.staticText ?? "").isEmpty)
        }.max { score($0) < score($1) }
    }
    static func score(_ lyrics: Lyrics) -> Int {
        if lyrics.lines.contains(where: { !$0.words.isEmpty }) { return 3 }
        return lyrics.lines.isEmpty ? 1 : 2
    }
}

enum TranslationMappingError: LocalizedError {
    case missingOriginal, empty, countMismatch, timestampsMismatch
    var errorDescription: String? {
        switch self {
        case .missingOriginal: return "請先匯入或取得原文歌詞，再加入翻譯。"
        case .empty: return "翻譯內容是空的，請選擇有文字的檔案。"
        case .countMismatch: return "翻譯行數與原文不同。請提供逐行對應的文字，或使用有時間標記的翻譯 LRC。"
        case .timestampsMismatch: return "翻譯時間標記無法與原文一一對齊，請確認是同一錄音版本。"
        }
    }
}

enum TranslationMapper {
    static func apply(_ text: String, to original: Lyrics) throws -> Lyrics {
        guard !original.lines.isEmpty || !(original.staticText ?? "").isEmpty else { throw TranslationMappingError.missingOriginal }
        let translated = LRCParser.parse(text)
        var result = original
        if original.lines.isEmpty {
            let value = translated.staticText ?? translated.lines.map(\.text).joined(separator: "\n")
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TranslationMappingError.empty }
            result.staticTranslation = value
            return result
        }
        if translated.lines.isEmpty {
            let rows = (translated.staticText ?? "").components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let indexes = original.lines.indices.filter { !original.lines[$0].text.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !rows.isEmpty else { throw TranslationMappingError.empty }
            guard rows.count == indexes.count else { throw TranslationMappingError.countMismatch }
            for (row, index) in zip(rows, indexes) { result.lines[index].translation = row }
        } else {
            var used = Set<Int>()
            for index in original.lines.indices where !original.lines[index].text.isEmpty {
                let time = original.lines[index].time + original.offset
                let matches = translated.lines.indices.filter {
                    !used.contains($0) && abs(translated.lines[$0].time + translated.offset - time) <= 0.35
                }
                guard let match = matches.min(by: {
                    abs(translated.lines[$0].time + translated.offset - time) < abs(translated.lines[$1].time + translated.offset - time)
                }) else { throw TranslationMappingError.timestampsMismatch }
                result.lines[index].translation = translated.lines[match].text
                used.insert(match)
            }
            guard translated.lines.indices.filter({ !translated.lines[$0].text.isEmpty }).allSatisfy({ used.contains($0) }) else {
                throw TranslationMappingError.timestampsMismatch
            }
        }
        return result
    }
}
