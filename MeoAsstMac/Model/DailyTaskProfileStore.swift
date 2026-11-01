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
            return DailyTask(id: task.id, task: .infrast(config), enabled: task.enabled)
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
struct ProfileIdentity: Codable, Equatable {
    let id: String
    var displayName: String
    let createdAt: Date
}

/// Registry and task storage for multiple daily-task profiles (pure
/// Foundation; UI wiring, `--config` and switch notifications are P03.2,
/// versioned migrations beyond `formatVersion` 1 are P03.3).
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
    private struct Index: Codable, Equatable {
        let formatVersion: Int
        var profiles: [ProfileIdentity]
        var activeProfileID: String
    }

    static let defaultProfileID = "Default"
    static let currentFormatVersion = 1

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

    /// Switching only moves the active pointer; change notifications are P03.2.
    func setActive(_ profileID: String) throws {
        var index = try loadIndex()
        guard index.profiles.contains(where: { $0.id == profileID }) else {
            throw ProfileError.profileNotFound(id: profileID)
        }
        guard index.activeProfileID != profileID else { return }
        index.activeProfileID = profileID
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

    /// Load the registry, bootstrapping it on first run and repairing a
    /// damaged one by rescanning the directory.
    private func loadIndex() throws -> Index {
        var persisted: Index?
        if let data = try? Data(contentsOf: indexURL) {
            persisted = try? PropertyListDecoder().decode(Index.self, from: data)
            if let persisted, persisted.formatVersion > Self.currentFormatVersion {
                throw ProfileError.unsupportedIndexVersion(persisted.formatVersion)
            }
        }

        // First run (no index) or a corrupt one: rebuild from the files on
        // disk so legacy installations migrate losslessly and in place.
        // sanitize/scan keep the active pointer on a registered profile, so
        // an empty registry from the file falls back to a fresh Default.
        var index = persisted.map(sanitize) ?? scan()
        if index.profiles.isEmpty { index = scan() }
        if index != persisted { try persist(index) }
        return index
    }

    /// Drop duplicate ids and clamp the active pointer to a real profile.
    private func sanitize(_ index: Index) -> Index {
        var seen = Set<String>()
        var sanitized = index
        sanitized.profiles = index.profiles.filter { seen.insert($0.id).inserted }
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
            guard !id.isEmpty, ![".", ".."].contains(id),
                URL(fileURLWithPath: id).lastPathComponent == id else { continue }
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
        return Index(formatVersion: Self.currentFormatVersion, profiles: profiles, activeProfileID: active)
    }

    /// Atomic replace: a crash mid-write can never destroy the previous index.
    private func persist(_ index: Index) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try PropertyListEncoder().encode(index).write(to: indexURL, options: .atomic)
    }
}
