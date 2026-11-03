import Foundation

// P03.1 multi-profile storage layer: CRUD, active switching, legacy migration,
// corrupt-index recovery and interrupted writes. All via injected temp roots.

func check(_ condition: Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(condition, "Profile store regression", file: file, line: line)
}

private func withProfileRoot(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}

private func tasks(_ names: [String]) -> [DailyTask] {
    names.map { DailyTask(id: UUID(), task: .closedown($0), enabled: true) }
}

private func profileFile(_ root: URL, _ id: String) -> URL {
    root.appendingPathComponent(id).appendingPathExtension("plist")
}

private func sidecarFile(_ root: URL, _ id: String) -> URL {
    root.appendingPathComponent("FiammettaPreferences/\(id).plist")
}

private func expectError(_ expected: ProfileStore.ProfileError, _ body: () throws -> Void) {
    do {
        try body()
        check(false)
    } catch let error as ProfileStore.ProfileError {
        check(error == expected)
    } catch {
        check(false)
    }
}

func testProfileStoreBootstrapAndMigration() throws {
    try withProfileRoot { root in
        // Fresh root: bootstrap registers Default as the active profile.
        let store = ProfileStore(rootURL: root)
        let identities = try store.list()
        check(identities.map(\.id) == [ProfileStore.defaultProfileID])
        check(identities[0].displayName == ProfileStore.defaultProfileID)
        check(try store.activeProfileID() == ProfileStore.defaultProfileID)
        // Registered but never saved: the tasks list reads back empty.
        check(try store.loadTasks(profileID: ProfileStore.defaultProfileID) == [])
        let index = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: root.appendingPathComponent("index.plist")), format: nil) as! [String: Any]
        check(index["formatVersion"] as! Int == ProfileStore.currentFormatVersion)
    }

    // First run without index but with the legacy single-profile file (the
    // pre-P03 save() target): migrate in place, keeping the old file intact.
    try withProfileRoot { legacy in
        let legacyTasks = tasks(["唤醒", "基建", "公招"])
        let legacyURL = legacy.appendingPathComponent("Default.plist")
        try PropertyListEncoder().encode(legacyTasks).write(to: legacyURL, options: .atomic)
        let oldBytes = try Data(contentsOf: legacyURL)

        let migrated = ProfileStore(rootURL: legacy)
        check(try migrated.list().map(\.id) == [ProfileStore.defaultProfileID])
        check(try migrated.activeProfileID() == ProfileStore.defaultProfileID)
        check(try migrated.loadTasks(profileID: ProfileStore.defaultProfileID) == legacyTasks)
        check(FileManager.default.fileExists(atPath: legacyURL.path))
        check(try Data(contentsOf: legacyURL) == oldBytes)
    }
}

func testProfileStoreCRUDAndSwitching() throws {
    try withProfileRoot { root in
        let store = ProfileStore(rootURL: root)
        let defaultTasks = tasks(["默认档案任务"])
        try store.saveTasks(profileID: ProfileStore.defaultProfileID, tasks: defaultTasks)

        // Create: UUID id, preserved display name, appended after Default.
        let second = try store.create(name: "小号")
        check(second.id != ProfileStore.defaultProfileID)
        check(UUID(uuidString: second.id) != nil)
        check(second.displayName == "小号")
        check(try store.list().map(\.id) == [ProfileStore.defaultProfileID, second.id])
        check(try store.loadTasks(profileID: second.id) == [])
        check(try store.activeProfileID() == ProfileStore.defaultProfileID)

        // Save/load through the tolerant per-profile codec.
        let secondTasks = tasks(["小号专享"])
        try store.saveTasks(profileID: second.id, tasks: secondTasks)
        check(try store.loadTasks(profileID: second.id) == secondTasks)
        check(try store.loadTasks(profileID: ProfileStore.defaultProfileID) == defaultTasks)
        // The Fiammetta sidecar lands next to the profile it belongs to.
        check(FileManager.default.fileExists(atPath: sidecarFile(root, second.id).path))

        // Duplicate: identical content, distinct disk identity, source intact.
        let copy = try store.duplicate(second.id)
        check(copy.id != second.id)
        check(copy.displayName == "小号 副本")
        check(try store.loadTasks(profileID: copy.id) == secondTasks)
        let copyOnly = tasks(["只改副本"])
        try store.saveTasks(profileID: copy.id, tasks: copyOnly)
        check(try store.loadTasks(profileID: second.id) == secondTasks)
        check(try store.list().map(\.id) == [ProfileStore.defaultProfileID, second.id, copy.id])

        // Rename only changes the displayed name, never the disk identity.
        try store.rename(second.id, to: "大号")
        check(try store.list().first { $0.id == second.id }!.displayName == "大号")
        check(try store.loadTasks(profileID: second.id) == secondTasks)

        // Switching the active pointer swaps which tasks the caller reads.
        try store.setActive(second.id)
        check(try store.activeProfileID() == second.id)
        check(try store.loadTasks(profileID: try store.activeProfileID()) == secondTasks)
        try store.setActive(ProfileStore.defaultProfileID)
        check(try store.loadTasks(profileID: try store.activeProfileID()) == defaultTasks)
        try store.setActive(ProfileStore.defaultProfileID)  // idempotent no-op
        expectError(.profileNotFound(id: "missing")) { try store.setActive("missing") }

        // Delete: non-active only; index entry, tasks file and sidecar go away.
        try store.setActive(second.id)
        expectError(.cannotDeleteActiveProfile(id: second.id)) { try store.delete(second.id) }
        try store.delete(copy.id)
        check(try store.list().map(\.id) == [ProfileStore.defaultProfileID, second.id])
        check(!FileManager.default.fileExists(atPath: profileFile(root, copy.id).path))
        check(!FileManager.default.fileExists(atPath: sidecarFile(root, copy.id).path))
        expectError(.profileNotFound(id: copy.id)) { try store.delete(copy.id) }
        expectError(.profileNotFound(id: "missing")) { try store.delete("missing") }
        expectError(.profileNotFound(id: "missing")) { _ = try store.loadTasks(profileID: "missing") }
        expectError(.profileNotFound(id: "missing")) { try store.saveTasks(profileID: "missing", tasks: []) }

        // A stale active pointer in the index is repaired, never crashing.
        var raw = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: root.appendingPathComponent("index.plist")), format: nil) as! [String: Any]
        raw["activeProfileID"] = "gone"
        try PropertyListSerialization.data(fromPropertyList: raw, format: .binary, options: 0)
            .write(to: root.appendingPathComponent("index.plist"))
        check(try store.activeProfileID() == ProfileStore.defaultProfileID)
    }
}

func testProfileStoreCorruptIndexRecovery() throws {
    try withProfileRoot { root in
        let store = ProfileStore(rootURL: root)
        let defaultTasks = tasks(["默认"])
        try store.saveTasks(profileID: ProfileStore.defaultProfileID, tasks: defaultTasks)
        let second = try store.create(name: "二号")
        let secondTasks = tasks(["二号任务"])
        try store.saveTasks(profileID: second.id, tasks: secondTasks)

        // Corrupt index: degrade to a directory scan and rebuild in place.
        try Data("not a plist".utf8).write(to: root.appendingPathComponent("index.plist"))
        check(try store.list().map(\.id) == [ProfileStore.defaultProfileID, second.id])
        check(try store.activeProfileID() == ProfileStore.defaultProfileID)
        check(try store.loadTasks(profileID: ProfileStore.defaultProfileID) == defaultTasks)
        check(try store.loadTasks(profileID: second.id) == secondTasks)
        // The rebuilt index is a valid versioned plist again.
        let index = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: root.appendingPathComponent("index.plist")), format: nil) as! [String: Any]
        check(index["formatVersion"] as! Int == ProfileStore.currentFormatVersion)

        // A future format version is refused instead of silently rewritten.
        var future = index
        future["formatVersion"] = ProfileStore.currentFormatVersion + 1
        try PropertyListSerialization.data(fromPropertyList: future, format: .binary, options: 0)
            .write(to: root.appendingPathComponent("index.plist"))
        expectError(.unsupportedIndexVersion(ProfileStore.currentFormatVersion + 1)) { _ = try store.list() }
    }
}

func testProfileStoreInterruptedIndexWrite() throws {
    try withProfileRoot { root in
        let store = ProfileStore(rootURL: root)
        let second = try store.create(name: "二号")
        let before = try store.list()
        let savedTasks = tasks(["旧数据"])
        try store.saveTasks(profileID: ProfileStore.defaultProfileID, tasks: savedTasks)
        let indexURL = root.appendingPathComponent("index.plist")
        let oldIndex = try Data(contentsOf: indexURL)

        // A read-only root makes every registry write fail where the atomic
        // replace happens, i.e. before the old index is touched.
        func denyWrites() { try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path) }
        func allowWrites() { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }
        denyWrites()
        do { _ = try store.create(name: "写不进去"); check(false) } catch {}
        do { try store.rename(ProfileStore.defaultProfileID, to: "改不动"); check(false) } catch {}
        do { try store.setActive(second.id); check(false) } catch {}
        do { try store.delete(second.id); check(false) } catch {}
        // Reads keep working against the intact old registry.
        check(try store.list() == before)
        check(try store.loadTasks(profileID: ProfileStore.defaultProfileID) == savedTasks)
        allowWrites()

        // Old data survived the failed writes untouched.
        check(try Data(contentsOf: indexURL) == oldIndex)
        check(try store.list() == before)
        check(try store.loadTasks(profileID: ProfileStore.defaultProfileID) == savedTasks)
    }
}

func testProfileStoreConfigArgumentResolution() throws {
    try withProfileRoot { root in
        let store = ProfileStore(rootURL: root)
        let second = try store.create(name: "小号")
        try store.rename(second.id, to: "大号")
        let clashA = try store.create(name: "同名")
        let clashB = try store.create(name: "同名")
        let identities = try store.list()

        // Exact id always resolves, even when a display name matches another profile.
        check(ProfileStore.resolveConfigArgument(second.id, identities: identities) == .resolved(second.id))
        // A unique display name resolves to that profile's stable disk id.
        check(ProfileStore.resolveConfigArgument("大号", identities: identities) == .resolved(second.id))
        // The default profile resolves by both its id and its display name.
        check(ProfileStore.resolveConfigArgument("Default", identities: identities)
            == .resolved(ProfileStore.defaultProfileID))
        // Ambiguous display names refuse to guess between the matches.
        check(ProfileStore.resolveConfigArgument("同名", identities: identities)
            == .ambiguous(argument: "同名", matches: [clashA.id, clashB.id]))
        // Unknown values never resolve.
        check(ProfileStore.resolveConfigArgument("missing", identities: identities) == .notFound(argument: "missing"))
        check(ProfileStore.resolveConfigArgument(ProfileStore.defaultProfileID, identities: [])
            == .notFound(argument: ProfileStore.defaultProfileID))

        // A resolved --config value is applied by switching the active pointer.
        try store.setActive(second.id)
        check(try store.activeProfileID() == second.id)
        try store.setActive(ProfileStore.defaultProfileID)
    }
}

func testProfileStoreRunOnceSurvivesRoundTrip() throws {
    try withProfileRoot { root in
        let store = ProfileStore(rootURL: root)
        // An armed infrast task gets a Fiammetta sidecar entry on save, so the
        // load-side tolerant restore rebuilds the DailyTask from scratch; the
        // rebuild must carry the run-once flag (R3 regression).
        var infrast = InfrastConfiguration()
        infrast.mode = .custom
        infrast.filename = "Plan A"
        let armedInfra = DailyTask(id: UUID(), task: .infrast(infrast), enabled: true, runOnce: true)
        let armedPlain = DailyTask(id: UUID(), task: .closedown("收尾"), enabled: true, runOnce: true)
        try store.saveTasks(profileID: ProfileStore.defaultProfileID, tasks: [armedInfra, armedPlain])
        let loaded = try store.loadTasks(profileID: ProfileStore.defaultProfileID)
        // Whole-struct Equatable: the sidecar-restore rebuild must keep runOnce.
        check(loaded[0] == armedInfra)
        check(loaded[1] == armedPlain)
    }
}

// P03.3 versioned index migration: v1 bytes upgrade in place through the
// migration chain, same-version round-trips stay byte-stable, and a newer
// index — decodable or schema-broken — is refused without any write-back.

private func indexURL(_ root: URL) -> URL {
    root.appendingPathComponent("index.plist")
}

private func readIndexDictionary(_ root: URL) throws -> [String: Any] {
    try PropertyListSerialization.propertyList(from: try Data(contentsOf: indexURL(root)), format: nil)
        as! [String: Any]
}

private func writeIndexDictionary(_ dictionary: [String: Any], to root: URL) throws {
    try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
        .write(to: indexURL(root))
}

func testProfileStoreIndexMigrationChain() throws {
    let secondID = "22222222-2222-2222-2222-222222222222"
    let v1Index: [String: Any] = [
        "formatVersion": 1,
        "profiles": [
            ["id": ProfileStore.defaultProfileID, "displayName": "默认",
             "createdAt": Date(timeIntervalSince1970: 50)],
            ["id": secondID, "displayName": "小号", "createdAt": Date(timeIntervalSince1970: 60)],
        ],
        "activeProfileID": ProfileStore.defaultProfileID,
    ]

    // A v1 (P03.1/P03.2 era) index upgrades in place on first load: identities
    // (including renamed display names — proof of migration, not a scan
    // rebuild), the active pointer and task files all survive; lastSwitchedAt
    // takes its "never switched" default (key absent = nil).
    try withProfileRoot { root in
        try writeIndexDictionary(v1Index, to: root)
        let defaultTasks = tasks(["旧档案任务"])
        try PropertyListEncoder().encode(defaultTasks)
            .write(to: profileFile(root, ProfileStore.defaultProfileID), options: .atomic)
        let taskBytes = try Data(contentsOf: profileFile(root, ProfileStore.defaultProfileID))

        let store = ProfileStore(rootURL: root)
        check(try store.list().map(\.id) == [ProfileStore.defaultProfileID, secondID])
        check(try store.list().map(\.displayName) == ["默认", "小号"])
        check(try store.activeProfileID() == ProfileStore.defaultProfileID)
        check(try store.loadTasks(profileID: ProfileStore.defaultProfileID) == defaultTasks)
        check(try Data(contentsOf: profileFile(root, ProfileStore.defaultProfileID)) == taskBytes)

        let upgraded = try readIndexDictionary(root)
        check(upgraded["formatVersion"] as! Int == ProfileStore.currentFormatVersion)
        check(upgraded["lastSwitchedAt"] == nil)
        // Same-version reload is byte-stable: no rewrite churn after upgrading.
        let stableBytes = try Data(contentsOf: indexURL(root))
        _ = try store.list()
        check(try Data(contentsOf: indexURL(root)) == stableBytes)

        // v2 semantics: moving the active pointer stamps lastSwitchedAt.
        try store.setActive(secondID)
        let switched = try readIndexDictionary(root)
        check(switched["activeProfileID"] as! String == secondID)
        check(switched["lastSwitchedAt"] is Date)
    }

    // Pure chain: v1 bytes walk to the current format with every field kept;
    // a current-version input passes through; a newer version is refused.
    let v1Bytes = try PropertyListSerialization.data(fromPropertyList: v1Index, format: .binary, options: 0)
    let (migratedBytes, version) = try IndexMigration.migrate(index: v1Bytes, from: 1)
    check(version == ProfileStore.currentFormatVersion)
    let migrated = try PropertyListSerialization.propertyList(from: migratedBytes, format: nil) as! [String: Any]
    check(migrated["formatVersion"] as! Int == ProfileStore.currentFormatVersion)
    check((migrated["profiles"] as! [[String: Any]]).map { $0["displayName"] as! String } == ["默认", "小号"])
    check(migrated["activeProfileID"] as! String == ProfileStore.defaultProfileID)
    let passthrough = try IndexMigration.migrate(index: migratedBytes, from: version)
    check(passthrough.1 == version && passthrough.0 == migratedBytes)
    expectError(.unsupportedIndexVersion(ProfileStore.currentFormatVersion + 1)) {
        _ = try IndexMigration.migrate(index: migratedBytes, from: ProfileStore.currentFormatVersion + 1)
    }
}

func testProfileStoreFutureIndexRefusal() throws {
    // 旧版本读写不丢设置：任何"新档案遇旧代码"都拒绝且零写回。伪造
    // current+1 与 v1 代码读 v2 走同一判别（formatVersion > current 即 throw）。
    try withProfileRoot { root in
        let store = ProfileStore(rootURL: root)
        _ = try store.create(name: "二号")
        var future = try readIndexDictionary(root)
        future["formatVersion"] = ProfileStore.currentFormatVersion + 1
        try writeIndexDictionary(future, to: root)
        let futureBytes = try Data(contentsOf: indexURL(root))
        expectError(.unsupportedIndexVersion(ProfileStore.currentFormatVersion + 1)) { _ = try store.list() }
        expectError(.unsupportedIndexVersion(ProfileStore.currentFormatVersion + 1)) {
            try store.setActive(ProfileStore.defaultProfileID)
        }
        check(try Data(contentsOf: indexURL(root)) == futureBytes)
    }

    // R3-1: a schema-breaking future index (decode fails, e.g. a renamed or
    // retyped field) must be refused by the raw version probe — not silently
    // rewritten by the corrupt-index scan fallback.
    try withProfileRoot { root in
        let store = ProfileStore(rootURL: root)
        _ = try store.create(name: "二号")
        var broken = try readIndexDictionary(root)
        broken["formatVersion"] = ProfileStore.currentFormatVersion + 1
        broken["profiles"] = "schema changed"  // makes Index decoding fail
        try writeIndexDictionary(broken, to: root)
        let brokenBytes = try Data(contentsOf: indexURL(root))
        expectError(.unsupportedIndexVersion(ProfileStore.currentFormatVersion + 1)) { _ = try store.list() }
        check(try Data(contentsOf: indexURL(root)) == brokenBytes)
    }

    // Even a retyped formatVersion (String) is probed and refused.
    try withProfileRoot { root in
        let store = ProfileStore(rootURL: root)
        _ = try store.create(name: "二号")
        var retyped = try readIndexDictionary(root)
        retyped["formatVersion"] = "\(ProfileStore.currentFormatVersion + 1)"
        try writeIndexDictionary(retyped, to: root)
        let retypedBytes = try Data(contentsOf: indexURL(root))
        expectError(.unsupportedIndexVersion(ProfileStore.currentFormatVersion + 1)) { _ = try store.list() }
        check(try Data(contentsOf: indexURL(root)) == retypedBytes)
    }
}

func testProfileStoreUnsafeStemSanitization() throws {
    // R3-2: a hand-tampered index cannot smuggle path-escaping ids into the
    // registry; sanitize drops them exactly like scan() skips unsafe files.
    try withProfileRoot { root in
        let store = ProfileStore(rootURL: root)
        _ = try store.list()  // bootstrap the registry first
        var tampered = try readIndexDictionary(root)
        tampered["profiles"] = [
            ["id": ProfileStore.defaultProfileID, "displayName": "Default", "createdAt": Date()],
            ["id": "../escape", "displayName": "逃逸", "createdAt": Date()],
        ]
        try writeIndexDictionary(tampered, to: root)

        check(try store.list().map(\.id) == [ProfileStore.defaultProfileID])
        expectError(.profileNotFound(id: "../escape")) { _ = try store.loadTasks(profileID: "../escape") }
        expectError(.profileNotFound(id: "../escape")) { try store.delete("../escape") }
        check((try readIndexDictionary(root)["profiles"] as! [[String: Any]]).count == 1)
        // The legitimate entry keeps working after the cleanup.
        check(try store.loadTasks(profileID: ProfileStore.defaultProfileID) == [])
    }
}

try testProfileStoreBootstrapAndMigration()
try testProfileStoreCRUDAndSwitching()
try testProfileStoreCorruptIndexRecovery()
try testProfileStoreInterruptedIndexWrite()
try testProfileStoreConfigArgumentResolution()
try testProfileStoreRunOnceSurvivesRoundTrip()
try testProfileStoreIndexMigrationChain()
try testProfileStoreFutureIndexRefusal()
try testProfileStoreUnsafeStemSanitization()
print(
    "PASS: profile store bootstrap, legacy Default migration, create/duplicate/rename/delete, "
        + "active switching, corrupt-index scan recovery, future-version refusal, interrupted index writes, "
        + "--config argument resolution, index migration chain (v1→v2) and unsafe-stem sanitization")
