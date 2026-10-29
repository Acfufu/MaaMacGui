import Foundation

/// Keeps Fiammetta preferences outside the plist that older app versions rewrite.
struct DailyTaskProfileStore {
    let profileURL: URL

    private var preferencesURL: URL {
        profileURL.deletingLastPathComponent()
            .appendingPathComponent("FiammettaPreferences", isDirectory: true)
            .appendingPathComponent(profileURL.lastPathComponent)
    }

    private struct Preferences: Codable {
        var recoveryEnabled: Bool?
        var targets: [String]?

        enum CodingKeys: String, CodingKey {
            case recoveryEnabled = "fiammetta_recovery_enabled"
            case targets = "fiammetta_targets"
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

        let preferences: [String: Preferences]
        do {
            preferences = try PropertyListDecoder().decode(
                [String: Preferences].self, from: Data(contentsOf: preferencesURL))
        } catch {
            // An unreadable backup must not send an otherwise valid profile down
            // the startup path that replaces all tasks with defaults.
            print("Failed to load Fiammetta preferences: \(error)")
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
