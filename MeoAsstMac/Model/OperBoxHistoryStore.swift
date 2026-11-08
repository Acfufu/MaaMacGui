import Foundation

/// A stable snapshot of fields actually emitted by OperBox. Skill/mastery and
/// module data are deliberately absent: the recognition callback does not supply them.
struct OperBoxHistoryPayload: Codable, Equatable, Sendable {
    struct Operator: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let own: Bool
        let name: String
        let rarity: Int
    }
    struct OwnedOperator: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let own: Bool
        let name: String
        let rarity: Int
        let elite: Int
        let level: Int
        let potential: Int
    }
    let done: Bool
    let allOperators: [Operator]
    let ownedOperators: [OwnedOperator]

    var isValid: Bool {
        done && !allOperators.isEmpty && !ownedOperators.isEmpty && Set(allOperators.map(\.id)).count == allOperators.count
            && Set(ownedOperators.map(\.id)).count == ownedOperators.count
            && allOperators.allSatisfy { !$0.id.isEmpty && !$0.name.isEmpty && $0.rarity >= 0 }
            && ownedOperators.allSatisfy {
                !$0.id.isEmpty && !$0.name.isEmpty && $0.rarity >= 0
                    && $0.elite >= 0 && $0.level >= 0 && $0.potential >= 0
            }
    }
}

struct OperBoxHistoryStore {
    struct Snapshot: Codable, Equatable {
        let schemaVersion: Int
        let scope: InventoryScope
        let capturedAt: Date
        let operators: OperBoxHistoryPayload
    }
    let directory: URL

    func save(_ operators: OperBoxHistoryPayload, scope: InventoryScope, now: Date = .now) throws {
        guard !scope.account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DepotHistoryStore.StoreError.invalidAccount
        }
        guard operators.isValid, now.timeIntervalSince1970.isFinite else {
            throw DepotHistoryStore.StoreError.invalidSnapshot
        }
        let record = Snapshot(schemaVersion: 1, scope: scope, capturedAt: now, operators: operators)
        try HistoryFileIO.write(JSONEncoder().encode(record), scope: scope, directory: directory)
    }

    func load(scope: InventoryScope) throws -> Snapshot? {
        guard !scope.account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let file = try HistoryFileIO.fileURL(scope: scope, directory: directory)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let record = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file))
        guard record.schemaVersion == 1 else { throw DepotHistoryStore.StoreError.incompatibleSchema }
        guard record.scope == scope, record.operators.isValid,
              record.capturedAt.timeIntervalSince1970.isFinite else {
            throw DepotHistoryStore.StoreError.invalidSnapshot
        }
        return record
    }
}
