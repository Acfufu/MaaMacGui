import CryptoKit
import Foundation

/// Historical records never become InventorySnapshotAdapter's live inventory.
/// They are written only by the owned, successful Depot chain completion.
struct DepotHistoryStore {
    struct Snapshot: Codable, Equatable {
        let schemaVersion: Int
        let scope: InventoryScope
        let capturedAt: Date
        let items: [String: Int]
    }
    enum StoreError: Error { case invalidAccount, invalidSnapshot, incompatibleSchema }
    let directory: URL

    func save(items: [String: Int], complete: Bool, scope: InventoryScope, now: Date = .now) throws {
        guard !scope.account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StoreError.invalidAccount
        }
        guard complete, now.timeIntervalSince1970.isFinite,
              items.values.allSatisfy({ $0 >= 0 }) else { throw StoreError.invalidSnapshot }
        let record = Snapshot(schemaVersion: 1, scope: scope, capturedAt: now, items: items)
        let bytes = try JSONEncoder().encode(record)
        try HistoryFileIO.write(bytes, scope: scope, directory: directory)
    }

    func load(scope: InventoryScope) throws -> Snapshot? {
        guard !scope.account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let url = try fileURL(scope: scope)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let record = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
        guard record.schemaVersion == 1 else { throw StoreError.incompatibleSchema }
        guard record.scope == scope, record.capturedAt.timeIntervalSince1970.isFinite,
              record.items.values.allSatisfy({ $0 >= 0 }) else { throw StoreError.invalidSnapshot }
        return record
    }

    func fileURL(scope: InventoryScope) throws -> URL {
        try HistoryFileIO.fileURL(scope: scope, directory: directory)
    }
}

enum HistoryFileIO {
    static func fileURL(scope: InventoryScope, directory: URL) throws -> URL {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let hash = SHA256.hash(data: try encoder.encode(scope)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash).appendingPathExtension("json")
    }

    static func write(_ bytes: Data, scope: InventoryScope, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: fileURL(scope: scope, directory: directory), options: .atomic)
    }
}

// MARK: - App integration
