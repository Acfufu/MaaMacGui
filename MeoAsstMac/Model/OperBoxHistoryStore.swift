import Foundation

struct OperBoxHistoryStore {
    struct Snapshot: Codable, Equatable {
        let schemaVersion: Int
        let scope: InventoryScope
        let capturedAt: Date
        let operators: OperBoxHistoryPayload
        /// 数据来源（WPF _operBoxDataSource 同位）："yituliu" 或 nil=本地识别。
        let source: String?

        init(schemaVersion: Int, scope: InventoryScope, capturedAt: Date, operators: OperBoxHistoryPayload, source: String? = nil) {
            self.schemaVersion = schemaVersion
            self.scope = scope
            self.capturedAt = capturedAt
            self.operators = operators
            self.source = source
        }
    }
    let directory: URL

    func save(_ operators: OperBoxHistoryPayload, scope: InventoryScope, now: Date = .now, source: String? = nil) throws {
        guard !scope.account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DepotHistoryStore.StoreError.invalidAccount
        }
        guard operators.isValid, now.timeIntervalSince1970.isFinite else {
            throw DepotHistoryStore.StoreError.invalidSnapshot
        }
        let record = Snapshot(schemaVersion: 1, scope: scope, capturedAt: now, operators: operators, source: source)
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
