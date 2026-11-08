import Foundation

/// Uses the daily coordinator's runID. No independent run identity or queue.
struct UserDataUpdateRun {
    struct Owner: Equatable {
        let runID: UUID
        let taskID: UUID
        let scope: InventoryScope
        let kind: UserDataKind
        let observedProfile: String

        init(runID: UUID, taskID: UUID, scope: InventoryScope, kind: UserDataKind, observedProfile: String? = nil) {
            self.runID = runID
            self.taskID = taskID
            self.scope = scope
            self.kind = kind
            self.observedProfile = observedProfile ?? scope.profile
        }
    }
    enum Payload {
        case depot(items: [String: Int], complete: Bool)
        case operators(OperBoxHistoryPayload)
        var kind: UserDataKind {
            switch self { case .depot: .depot; case .operators: .operBox }
        }
        var isComplete: Bool {
            switch self {
            case .depot(let items, let complete): complete && items.values.allSatisfy { $0 >= 0 }
            case .operators(let operators): operators.isValid
            }
        }
    }
    enum Progress: Equatable { case pending, running, succeeded, failed, cancelled }
    struct Entry {
        let owner: Owner
        var payload: Payload?
        var progress = Progress.pending
        var completionObserved = false
    }
    private(set) var entries: [Int32: Entry] = [:]
    private(set) var executionSubmitted = false

    mutating func register(_ coreID: Int32, owner: Owner) throws {
        guard coreID > 0, entries[coreID] == nil,
              entries.values.first.map({ $0.owner.runID == owner.runID }) ?? true else { throw CocoaError(.coderInvalidValue) }
        entries[coreID] = Entry(owner: owner)
    }
    mutating func reset() { entries.removeAll(); executionSubmitted = false }
    mutating func beginExecution() { executionSubmitted = true }
    func hasPending(runID: UUID) -> Bool {
        entries.values.contains { $0.owner.runID == runID && [.pending, .running].contains($0.progress) }
    }
    mutating func record(_ payload: Payload?, coreID: Int32) {
        guard let current = entries[coreID], [.pending, .running].contains(current.progress) else { return }
        guard payload.map({ $0.kind == current.owner.kind }) ?? true else { return }
        entries[coreID]?.payload = payload
    }
    mutating func observeCompletion(_ coreID: Int32) {
        guard let entry = entries[coreID], [.pending, .running].contains(entry.progress) else { return }
        entries[coreID]?.completionObserved = true
    }
    mutating func finish(_ coreID: Int32, as progress: Progress) {
        guard let current = entries[coreID], [.pending, .running].contains(current.progress) else { return }
        entries[coreID]?.progress = progress
    }
    mutating func cancelPending() {
        executionSubmitted = false
        for id in entries.keys where [.pending, .running].contains(entries[id]!.progress) {
            entries[id]?.progress = .cancelled
            entries[id]?.payload = nil
        }
    }
    func aggregate(for taskID: UUID) -> Progress? {
        let states = entries.values.filter { $0.owner.taskID == taskID }.map(\.progress)
        guard !states.isEmpty else { return nil }
        if states.contains(.failed) { return .failed }
        if states.contains(.cancelled) { return .cancelled }
        if states.allSatisfy({ $0 == .succeeded }) { return .succeeded }
        if states.allSatisfy({ $0 == .pending }) { return .pending }
        return .running
    }
}
