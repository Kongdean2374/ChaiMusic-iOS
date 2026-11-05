import Foundation

enum LRCParser {
    // 匯入時換算 LRC offset；內部正 offset 表示延後，由 Lyrics.activeIndex 換算。
    static func parse(_ text: String) -> Lyrics {
        var lyrics = Lyrics()
        let linePattern = try! NSRegularExpression(pattern: #"\[(\d+):(\d{1,2}(?:\.\d+)?)\]"#)
        let wordPattern = try! NSRegularExpression(pattern: #"<(\d+):(\d{1,2}(?:\.\d+)?)>"#)
        let offsetPattern = try! NSRegularExpression(pattern: #"\[offset:([+-]?\d+)\]"#, options: .caseInsensitive)
        for raw in text.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let range = NSRange(location: 0, length: ns.length)
            if let match = offsetPattern.firstMatch(in: raw, range: range),
               let milliseconds = Double(ns.substring(with: match.range(at: 1))) {
                // 常見 LRC 正 offset 是提早顯示，轉成內部延遲秒數。
                lyrics.offset = -milliseconds / 1000
            }
            let stamps = linePattern.matches(in: raw, range: range)
            guard let last = stamps.last else { continue }
            let body = ns.substring(from: NSMaxRange(last.range))
            let bodyNS = body as NSString
            let wordStamps = wordPattern.matches(in: body, range: NSRange(location: 0, length: bodyNS.length))
            var words: [LyricWord] = []
            for (index, match) in wordStamps.enumerated() {
                let start = NSMaxRange(match.range)
                let end = index + 1 < wordStamps.count ? wordStamps[index + 1].range.location : bodyNS.length
                let word = bodyNS.substring(with: NSRange(location: start, length: end - start))
                if !word.isEmpty { words.append(LyricWord(time: timestamp(match, in: bodyNS), text: word)) }
            }
            let clean = wordPattern.stringByReplacingMatches(in: body, range: NSRange(location: 0, length: bodyNS.length), withTemplate: "")
                .trimmingCharacters(in: .whitespaces)
            let baseTime = stamps.first.map { timestamp($0, in: ns) } ?? 0
            for stamp in stamps {
                let time = timestamp(stamp, in: ns)
                let shifted = words.map { LyricWord(time: max(0, $0.time + time - baseTime), text: $0.text) }
                lyrics.lines.append(LyricLine(time: time, text: clean, words: shifted))
            }
        }
        lyrics.lines.sort { $0.time < $1.time }
        return lyrics
    }
    private static func timestamp(_ match: NSTextCheckingResult, in string: NSString) -> Double {
        (Double(string.substring(with: match.range(at: 1))) ?? 0) * 60 +
        (Double(string.substring(with: match.range(at: 2))) ?? 0)
    }
}
