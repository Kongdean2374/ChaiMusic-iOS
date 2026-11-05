import Foundation

struct ListeningSlice: Equatable {
    var start: Date
    var seconds: Double
}

enum ListeningMath {
    /// 不把 seek、暫停或音源切換造成的時鐘跳動算成聆聽。
    static func audibleSeconds(mediaDelta: Double, wallDelta: Double, playing: Bool, seeking: Bool) -> Double {
        guard playing, !seeking, mediaDelta.isFinite, wallDelta.isFinite,
              mediaDelta > 0, wallDelta > 0, wallDelta < 5,
              mediaDelta <= wallDelta + 0.15 else { return 0 }
        return min(mediaDelta, wallDelta)
    }

    /// 依使用者當時的日曆，把跨午夜秒數歸入各自日期（包含夏令時間）。
    static func split(seconds: Double, endingAt end: Date, calendar: Calendar = .current) -> [ListeningSlice] {
        guard seconds.isFinite, seconds > 0 else { return [] }
        var cursor = end.addingTimeInterval(-seconds)
        var result: [ListeningSlice] = []
        while cursor < end {
            let day = calendar.startOfDay(for: cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > cursor else { break }
            let boundary = min(next, end)
            result.append(ListeningSlice(start: cursor, seconds: boundary.timeIntervalSince(cursor)))
            cursor = boundary
        }
        return result
    }
}
