import Foundation
import OSLog

private let logger = Logger(subsystem: "com.hguandl.MeoAsstMac", category: "DailyTaskProfileStore")

/// Keeps Fiammetta preferences outside the plist that older app versions rewrite.
struct DailyTaskProfileStore {
    let profileURL: URL

    private var preferencesURL: URL {
        profileURL.deletingLastPathComponent()
            .appendingPathComponent("FiammettaPreferences", isDirectory: true)
            .appendingPathComponent(profileURL.lastPathComponent)
    }

    private typealias Preferences = InfrastConfiguration.FiammettaPreferences

    // A single corrupted record must not discard the other tasks' backups.
    private struct TolerantPreferencesMap: Decodable {
        var values: [String: Preferences] = [:]

        private struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            for key in container.allKeys {
                do {
                    values[key.stringValue] = try container.decode(Preferences.self, forKey: key)
                } catch {
                    logger.warning(
                        "Ignoring corrupt Fiammetta backup for task \(key.stringValue): \(error, privacy: .public)")
                }
            }
        }
    }

    // Decode field presence separately: InfrastConfiguration supplies defaults for
    // missing fields, which would otherwise hide a rewrite by an older version.
    private struct StoredTask: Decodable {
        let task: Configuration

        struct Configuration: Decodable {
            let infrast: Payload?
        }

        struct Payload: Decodable {
            let _0: Preferences?
        }
    }

    func load() throws -> [DailyTask] {
        let data = try Data(contentsOf: profileURL)
        let tasks = try PropertyListDecoder().decode([DailyTask].self, from: data)
        guard FileManager.default.fileExists(atPath: preferencesURL.path) else { return tasks }

        // Keep I/O and decoding failures apart: NSError descriptions embed the
        // user's home-directory path, so they must stay under default privacy,
        // while DecodingError only exposes key names and type expectations.
        let sidecarData: Data
        do {
            sidecarData = try Data(contentsOf: preferencesURL)
        } catch {
            // An unreadable backup must not send an otherwise valid profile down
            // the startup path that replaces all tasks with defaults.
            logger.error("Failed to read Fiammetta preferences: \(error)")
            return tasks
        }

        let preferences: [String: Preferences]
        do {
            preferences = try PropertyListDecoder().decode(
                TolerantPreferencesMap.self, from: sidecarData
            ).values
        } catch {
            logger.error("Failed to decode Fiammetta preferences: \(error, privacy: .public)")
            return tasks
        }

        let storedTasks = try PropertyListDecoder().decode([StoredTask].self, from: data)
        return zip(tasks, storedTasks).map { task, stored in
            guard case .infrast(var config) = task.task,
                let backup = preferences[task.id.uuidString],
                let inline = stored.task.infrast?._0
            else { return task }

            // Explicit inline values, including false and [], always win over
            // a possibly older backup. Only restore fields that disappeared.
            config.fiammetta_targets = InfrastConfiguration.normalizedFiammettaTargets(
                inline.targets ?? backup.targets ?? config.fiammetta_targets)
            config.fiammetta_recovery_enabled =
                (inline.recoveryEnabled ?? backup.recoveryEnabled
                    ?? config.fiammetta_recovery_enabled) && !config.fiammetta_targets.isEmpty
            return DailyTask(id: task.id, task: .infrast(config), enabled: task.enabled,
                             runOnce: task.runOnce)
        }
    }

    func save(_ tasks: [DailyTask]) throws {
        // Keep the profile self-contained for existing installations and copies.
        // Write it first so a failed backup write still leaves the latest values
        // available to this version on its next launch.
        try PropertyListEncoder().encode(tasks).write(to: profileURL, options: .atomic)

        var preferences = [String: Preferences]()
        for task in tasks {
            guard case .infrast(let config) = task.task else { continue }
            let targets = InfrastConfiguration.normalizedFiammettaTargets(config.fiammetta_targets)
            preferences[task.id.uuidString] = Preferences(
                recoveryEnabled: config.fiammetta_recovery_enabled && !targets.isEmpty,
                targets: targets)
        }

        try FileManager.default.createDirectory(
            at: preferencesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Replacing the whole map also removes preferences for deleted tasks.
        try PropertyListEncoder().encode(preferences).write(to: preferencesURL, options: .atomic)
    }
}

// MARK: - Multi-Profile Store (P03)

/// Disk identity of one daily-task profile.
///
/// `id` doubles as the profile file stem. The legacy single-profile
/// installation migrates to the fixed id "Default" — the string the pre-P03
/// `DailyTaskProfile` user default, run snapshots and patches address it by —
/// while profiles created through `ProfileStore` receive a fresh UUID.
/// Renaming only changes `displayName`; the disk identity stays stable.
struct ProfileIdentity: Codable, Equatable, Identifiable {
    let id: String
    var displayName: String
    let createdAt: Date
}

/// Registry and task storage for multiple daily-task profiles (pure
/// Foundation; UI wiring, `--config` and switch notifications are P03.2,
/// versioned index migrations are P03.3 — see `IndexMigration`).
///
/// Layout inside the injectable `rootURL` — the app's existing
/// `…/Application Support/DailyTasks` directory, reusing pre-P03 files in
/// place so rollback keeps working:
///
/// - `<id>.plist` — one task list per profile, read and written through
///   `DailyTaskProfileStore` to keep its tolerant Fiammetta semantics;
/// - `FiammettaPreferences/<id>.plist` — per-profile sidecars (unchanged);
/// - `index.plist` — versioned registry: ordered identities + active pointer.
struct ProfileStore {
    enum ProfileError: Error, Equatable {
        /// No profile with this id is registered in the index.
        case profileNotFound(id: String)
        /// The active profile cannot be deleted; switch away first.
        case cannotDeleteActiveProfile(id: String)
        /// A future on-disk format; refuse rather than rewrite it (P03.3).
        case unsupportedIndexVersion(Int)
    }

    /// Ordered registry persisted as `index.plist`.
    struct Index: Codable, Equatable {
        let formatVersion: Int
        var profiles: [ProfileIdentity]
        var activeProfileID: String
        /// v2: when the active pointer last moved. Absent (nil) in v1 files
        /// and until the first switch after migration — additive-only so a
        /// v1 decoder still reads every v1 field.
        var lastSwitchedAt: Date?
    }

    static let defaultProfileID = "Default"
    /// v1 (P03.1): ordered identities + active pointer.
    /// v2 (P03.3): adds `lastSwitchedAt` (nil = never switched). Older files
    /// walk `IndexMigration` up to here in place; newer ones are refused.
    static let currentFormatVersion = 2

    /// The app's pre-P03 daily-task directory; profiles live directly in it.
    static func defaultRootURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DailyTasks", isDirectory: true)
    }

    let rootURL: URL

    private var indexURL: URL { rootURL.appendingPathComponent("index.plist", isDirectory: false) }

    private func profileURL(_ profileID: String) -> URL {
        rootURL.appendingPathComponent(profileID, isDirectory: false).appendingPathExtension("plist")
    }

    // MARK: Registry

    func list() throws -> [ProfileIdentity] {
        try loadIndex().profiles
    }

    func activeProfileID() throws -> String {
        try loadIndex().activeProfileID
    }

    /// Switching only moves the active pointer (v2 also stamps
    /// `lastSwitchedAt`); change notifications are P03.2.
    func setActive(_ profileID: String) throws {
        var index = try loadIndex()
        guard index.profiles.contains(where: { $0.id == profileID }) else {
            throw ProfileError.profileNotFound(id: profileID)
        }
        guard index.activeProfileID != profileID else { return }
        index.activeProfileID = profileID
        index.lastSwitchedAt = Date()
        try persist(index)
    }

    @discardableResult
    func create(name: String) throws -> ProfileIdentity {
        var index = try loadIndex()
        let identity = ProfileIdentity(id: UUID().uuidString, displayName: name, createdAt: Date())
        index.profiles.append(identity)
        try persist(index)
        return identity
    }

    @discardableResult
    func duplicate(_ profileID: String) throws -> ProfileIdentity {
        var index = try loadIndex()
        guard let source = index.profiles.first(where: { $0.id == profileID }) else {
            throw ProfileError.profileNotFound(id: profileID)
        }
        let copy = ProfileIdentity(
            id: UUID().uuidString, displayName: "\(source.displayName) 副本", createdAt: Date())
        // The copy's file lands before the index entry making it visible, so
        // an interrupted write leaves an invisible orphan at worst.
        try writeTasks(copy.id, try loadTasks(profileID: profileID))
        index.profiles.append(copy)
        try persist(index)
        return copy
    }

    func rename(_ profileID: String, to name: String) throws {
        var index = try loadIndex()
        guard let position = index.profiles.firstIndex(where: { $0.id == profileID }) else {
            throw ProfileError.profileNotFound(id: profileID)
        }
        index.profiles[position].displayName = name
        try persist(index)
    }

    func delete(_ profileID: String) throws {
        var index = try loadIndex()
        guard let position = index.profiles.firstIndex(where: { $0.id == profileID }) else {
            throw ProfileError.profileNotFound(id: profileID)
        }
        guard index.activeProfileID != profileID else {
            throw ProfileError.cannotDeleteActiveProfile(id: profileID)
        }
        // The index is the source of visibility: drop the entry first, so an
        // interrupted delete leaves at most an invisible orphan file.
        index.profiles.remove(at: position)
        try persist(index)
        for url in [profileURL(profileID), sidecarURL(profileID)]
        where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Tasks

    /// Registered-but-never-saved profiles read back empty; decoding keeps
    /// the tolerant Fiammetta-preferences recovery of `DailyTaskProfileStore`.
    func loadTasks(profileID: String) throws -> [DailyTask] {
        try requireRegistered(profileID)
        let url = profileURL(profileID)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try DailyTaskProfileStore(profileURL: url).load()
    }

    func saveTasks(profileID: String, tasks: [DailyTask]) throws {
        try requireRegistered(profileID)
        try writeTasks(profileID, tasks)
    }

    // MARK: Index handling

    private func requireRegistered(_ profileID: String) throws {
        let index = try loadIndex()
        guard index.profiles.contains(where: { $0.id == profileID }) else {
            throw ProfileError.profileNotFound(id: profileID)
        }
    }

    private func writeTasks(_ profileID: String, _ tasks: [DailyTask]) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try DailyTaskProfileStore(profileURL: profileURL(profileID)).save(tasks)
    }

    private func sidecarURL(_ profileID: String) -> URL {
        let url = profileURL(profileID)
        return url.deletingLastPathComponent()
            .appendingPathComponent("FiammettaPreferences", isDirectory: true)
            .appendingPathComponent(url.lastPathComponent)
    }

    /// Load the registry, bootstrapping it on first run, migrating older
    /// formats in place and repairing a damaged one by rescanning the
    /// directory.
    private func loadIndex() throws -> Index {
        var persisted: Index?
        var didMigrate = false
        if let data = try? Data(contentsOf: indexURL) {
            if let decoded = try? PropertyListDecoder().decode(Index.self, from: data) {
                if decoded.formatVersion > Self.currentFormatVersion {
                    throw ProfileError.unsupportedIndexVersion(decoded.formatVersion)
                }
                if decoded.formatVersion < Self.currentFormatVersion {
                    // Older formats walk the migration chain; the rewritten
                    // bytes are re-decoded so a broken step cannot reach the
                    // registry.
                    let (migrated, _) = try IndexMigration.migrate(
                        index: data, from: decoded.formatVersion)
                    persisted = try PropertyListDecoder().decode(Index.self, from: migrated)
                    didMigrate = true
                } else {
                    persisted = decoded
                }
            } else if let raw = Self.rawFormatVersion(of: data), raw > Self.currentFormatVersion {
                // R3-1: a schema-breaking future format fails Index decoding
                // but still names its version. Refuse it here, or the
                // corrupt-index fallback below would rewrite the file to
                // this build's format and destroy the newer metadata.
                throw ProfileError.unsupportedIndexVersion(raw)
            }
        }

        // First run (no index) or a corrupt one: rebuild from the files on
        // disk so legacy installations migrate losslessly and in place.
        // sanitize/scan keep the active pointer on a registered profile, so
        // an empty registry from the file falls back to a fresh Default.
        var index = persisted.map(sanitize) ?? scan()
        if index.profiles.isEmpty { index = scan() }
        // A migration persists immediately: leaving the older bytes on disk
        // would re-run the chain (and risk divergence) on every launch.
        if didMigrate || index != persisted { try persist(index) }
        return index
    }

    /// Raw `formatVersion` probe for undecodable indexes (R3-1). Only a
    /// positively-identified newer version matters here; anything else
    /// (missing, unparseable) falls through to the corrupt-index recovery.
    private static func rawFormatVersion(of data: Data) -> Int? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let raw = (plist as? [String: Any])?["formatVersion"] else { return nil }
        if let number = raw as? NSNumber { return number.intValue }
        if let string = raw as? String { return Int(string) }
        return nil
    }

    /// Ids double as file stems, so only plain single-component names may
    /// enter the registry (shared by scan and sanitize; R3-2).
    static func isSafeProfileStem(_ id: String) -> Bool {
        !id.isEmpty && ![".", ".."].contains(id)
            && URL(fileURLWithPath: id).lastPathComponent == id
    }

    /// Drop duplicate ids, unsafe file stems, and clamp the active pointer
    /// to a real profile.
    private func sanitize(_ index: Index) -> Index {
        var seen = Set<String>()
        var sanitized = index
        sanitized.profiles = index.profiles.filter {
            Self.isSafeProfileStem($0.id) && seen.insert($0.id).inserted
        }
        if !sanitized.profiles.contains(where: { $0.id == sanitized.activeProfileID }) {
            sanitized.activeProfileID = sanitized.profiles.first?.id ?? Self.defaultProfileID
        }
        return sanitized
    }

    /// Every `*.plist` besides the index is one profile whose id and display
    /// name default to its file stem. "Default" sorts first, then names.
    private func scan() -> Index {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: [.creationDateKey])) ?? []
        var profiles = [ProfileIdentity]()
        for url in entries
        where url.lastPathComponent != "index.plist" && url.pathExtension == "plist" {
            let id = url.deletingPathExtension().lastPathComponent
            // Ids become path components; skip non-plain single-component names.
            guard Self.isSafeProfileStem(id) else { continue }
            let createdAt =
                (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
            profiles.append(ProfileIdentity(id: id, displayName: id, createdAt: createdAt))
        }
        profiles.sort { lhs, rhs in
            switch (lhs.id == Self.defaultProfileID, rhs.id == Self.defaultProfileID) {
            case (true, false): return true
            case (false, true): return false
            default: return lhs.id < rhs.id
            }
        }
        if profiles.isEmpty {
            profiles.append(
                ProfileIdentity(id: Self.defaultProfileID, displayName: Self.defaultProfileID, createdAt: Date()))
        }
        let active = profiles.first(where: { $0.id == Self.defaultProfileID })?.id ?? profiles[0].id
        return Index(
            formatVersion: Self.currentFormatVersion, profiles: profiles,
            activeProfileID: active, lastSwitchedAt: nil)
    }

    /// Atomic replace: a crash mid-write can never destroy the previous index.
    private func persist(_ index: Index) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try PropertyListEncoder().encode(index).write(to: indexURL, options: .atomic)
    }

    // MARK: - Launch Argument (P03.2 / Q04)

    /// Outcome of resolving a `--config <id-or-name>` value against the registry.
    enum ConfigArgumentResolution: Equatable {
        case resolved(String)
        case notFound(argument: String)
        /// Several profiles share this display name; refuse to guess.
        case ambiguous(argument: String, matches: [String])
    }

    /// Resolve a `--config` value (pure; the caller applies `.resolved` via
    /// `setActive`). An exact id wins over display names; a display name must
    /// match exactly one profile, otherwise the launch keeps the saved active
    /// profile instead of guessing.
    static func resolveConfigArgument(_ argument: String, identities: [ProfileIdentity])
        -> ConfigArgumentResolution {
        if let exact = identities.first(where: { $0.id == argument }) {
            return .resolved(exact.id)
        }
        let byName = identities.filter { $0.displayName == argument }
        switch byName.count {
        case 1: return .resolved(byName[0].id)
        case 2...: return .ambiguous(argument: argument, matches: byName.map(\.id))
        default: return .notFound(argument: argument)
        }
    }
}

// MARK: - Index Migration (P03.3 / Q03)

/// Versioned rewrites of `index.plist` (P03.3 / Q03). Each step is a pure
/// `v(n) → v(n+1)` byte transform; `ProfileStore.loadIndex` walks files
/// older than `currentFormatVersion` up the chain in place and refuses
/// newer ones without writing anything back — the "旧版本读写不丢设置"
/// contract: an older build meeting a newer index throws, it never
/// downgrades or corrupts it.
enum IndexMigration {
    /// The hop out of `version`, or nil when this build knows no step for it
    /// (a gap below the formats it understands).
    private static func step(from version: Int) -> ((Data) throws -> Data)? {
        switch version {
        case 1: return v1toV2
        default: return nil
        }
    }

    /// Walk `data` from `version` up to the format this build writes. A
    /// same-version input passes through unchanged; a newer version throws
    /// — downgrades do not exist, because a newer file may use fields this
    /// build cannot reconstruct.
    static func migrate(index data: Data, from version: Int) throws -> (Data, Int) {
        guard version <= ProfileStore.currentFormatVersion else {
            throw ProfileStore.ProfileError.unsupportedIndexVersion(version)
        }
        var current = data
        var currentVersion = version
        while currentVersion < ProfileStore.currentFormatVersion {
            guard let rewrite = step(from: currentVersion) else {
                throw ProfileStore.ProfileError.unsupportedIndexVersion(currentVersion)
            }
            current = try rewrite(current)
            currentVersion += 1
        }
        return (current, currentVersion)
    }

    /// v1 → v2: introduce `lastSwitchedAt` with its "never switched"
    /// default. The typed round-trip preserves every v1 field — identities,
    /// their order and the active pointer — by construction.
    private static func v1toV2(_ data: Data) throws -> Data {
        let index = try PropertyListDecoder().decode(ProfileStore.Index.self, from: data)
        return try PropertyListEncoder().encode(ProfileStore.Index(
            formatVersion: index.formatVersion + 1,
            profiles: index.profiles,
            activeProfileID: index.activeProfileID,
            lastSwitchedAt: nil))
    }
}
