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

try testProfileStoreBootstrapAndMigration()
try testProfileStoreCRUDAndSwitching()
try testProfileStoreCorruptIndexRecovery()
try testProfileStoreInterruptedIndexWrite()
print(
    "PASS: profile store bootstrap, legacy Default migration, create/duplicate/rename/delete, "
        + "active switching, corrupt-index scan recovery, future-version refusal and interrupted index writes")
