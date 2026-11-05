import Foundation

struct QueueEngine {
    var state: QueueState
    init(state: QueueState = QueueState()) {
        self.state = state
        // 讀取持久狀態時只修正無效值，不重洗或截短完整排列。
        var seen = Set<UUID>()
        self.state.sourceIDs = state.sourceIDs.filter { seen.insert($0).inserted }
        self.state.index = max(-1, min(state.index, state.order.count))
        if !self.state.progress.isFinite || self.state.progress < 0 { self.state.progress = 0 }
    }

    var upcomingIDs: [UUID] {
        state.pending + Array(state.order.dropFirst(max(0, state.index + 1)))
    }

    mutating func start(ids: [UUID], startID: UUID? = nil, shuffle: Bool = false, playlistID: UUID? = nil) {
        var seen = Set<UUID>()
        let unique = ids.filter { seen.insert($0).inserted }
        let repeatMode = state.repeatMode
        state = QueueState()
        state.repeatMode = repeatMode
        state.sourceIDs = unique
        state.shuffled = shuffle
        state.playlistID = playlistID
        if shuffle {
            state.order = unique.shuffled()
            if let first = startID, let position = state.order.firstIndex(of: first) {
                state.order.swapAt(0, position)
            }
        } else {
            state.order = unique
            state.index = startID.flatMap { unique.firstIndex(of: $0) } ?? 0
        }
        state.currentID = state.order.indices.contains(state.index) ? state.order[state.index] : nil
    }

    mutating func advance(automatic: Bool = false) -> UUID? {
        if automatic, state.repeatMode == .one, let current = state.currentID {
            state.progress = 0
            return current
        }
        if let current = state.currentID { state.history.append(current) }
        state.progress = 0
        if !state.pending.isEmpty {
            state.currentID = state.pending.removeFirst()
        } else if state.index + 1 < state.order.count {
            state.index += 1
            state.currentID = state.order[state.index]
        } else if state.repeatMode == .all, !state.sourceIDs.isEmpty {
            state.order = state.shuffled ? state.sourceIDs.shuffled() : state.sourceIDs
            state.index = 0
            state.currentID = state.order.first
        } else {
            state.index = state.order.count
            state.currentID = nil
        }
        return state.currentID
    }

    mutating func previous() -> UUID? {
        guard let previous = state.history.popLast() else {
            state.progress = 0
            return state.currentID
        }
        if let current = state.currentID { state.pending.insert(current, at: 0) }
        state.currentID = previous
        state.progress = 0
        return previous
    }

    mutating func insertNext(_ id: UUID) { state.pending.insert(id, at: 0) }

    mutating func reconcile(validIDs: Set<UUID>) {
        let consumed = state.order.prefix(max(0, min(state.index + 1, state.order.count))).filter { validIDs.contains($0) }
        let remaining = state.order.dropFirst(max(0, state.index + 1)).filter { validIDs.contains($0) }
        state.order = consumed + remaining
        state.index = consumed.count - 1
        state.sourceIDs.removeAll { !validIDs.contains($0) }
        state.pending.removeAll { !validIDs.contains($0) }
        state.history.removeAll { !validIDs.contains($0) }
        if let current = state.currentID, !validIDs.contains(current) {
            state.currentID = nil
            _ = advance()
        }
    }

    mutating func setShuffle(_ enabled: Bool) {
        guard enabled != state.shuffled else { return }
        state.shuffled = enabled
        let prefix = Array(state.order.prefix(max(0, state.index + 1)))
        let remaining = Array(state.order.dropFirst(max(0, state.index + 1)))
        if enabled {
            state.order = prefix + remaining.shuffled()
        } else {
            let ranks = Dictionary(state.sourceIDs.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
            state.order = prefix + remaining.sorted { (ranks[$0] ?? Int.max) < (ranks[$1] ?? Int.max) }
        }
    }

    mutating func removeUpcoming(at offsets: IndexSet) {
        var future = upcomingIDs
        for index in offsets.sorted(by: >) where future.indices.contains(index) { future.remove(at: index) }
        replaceUpcoming(future)
    }

    mutating func moveUpcoming(from offsets: IndexSet, to destination: Int) {
        let future = upcomingIDs
        let selected = offsets.sorted().filter { future.indices.contains($0) }
        let moved = selected.map { future[$0] }
        var result = future.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        let insertion = max(0, min(result.count, destination - selected.filter { $0 < destination }.count))
        result.insert(contentsOf: moved, at: insertion)
        replaceUpcoming(result)
    }

    private mutating func replaceUpcoming(_ ids: [UUID]) {
        state.order = Array(state.order.prefix(max(0, state.index + 1))) + ids
        state.pending = []
    }
}
