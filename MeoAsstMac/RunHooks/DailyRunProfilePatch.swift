import Foundation

/// Only fields produced by a successful task callback may change a saved run profile.
enum DailyTaskCallbackUpdate {
    case infrastructurePlanIndex(Int)
    case creditFightDate(Date)
    case friendVisitDate(Date)

    func applying(to current: MAATask, expecting original: MAATask) -> MAATask? {
        switch (self, current, original) {
        case (.infrastructurePlanIndex(let next), .infrast(var latest), .infrast(let expected)):
            guard latest.mode == .custom, expected.mode == .custom,
                  latest.filename == expected.filename, latest.plan_index == expected.plan_index else { return nil }
            latest.plan_index = next
            return .infrast(latest)
        case (.creditFightDate(let date), .mall(var latest), .mall(let expected)):
            guard latest.creditFightDate == expected.creditFightDate else { return nil }
            latest.creditFightDate = date
            return .mall(latest)
        case (.friendVisitDate(let date), .mall(var latest), .mall(let expected)):
            guard latest.friendVisitDate == expected.friendVisitDate else { return nil }
            latest.friendVisitDate = date
            return .mall(latest)
        default:
            return nil
        }
    }
}

enum DailyRunProfilePatchStore {
    /// Read the latest original profile, then compare-and-patch one field.
    /// UI edits are authoritative when that original profile is currently selected.
    static func apply(_ update: DailyTaskCallbackUpdate, taskID: UUID, expected: MAATask,
                      profileID: String, currentTasks: [DailyTask]?, directory: URL) throws -> [DailyTask]? {
        guard !profileID.isEmpty, ![".", ".."].contains(profileID),
              URL(fileURLWithPath: profileID).lastPathComponent == profileID else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let url = directory.appendingPathComponent(profileID).appendingPathExtension("plist")
        var latest: [DailyTask]
        if let currentTasks {
            latest = currentTasks
        } else {
            latest = try PropertyListDecoder().decode([DailyTask].self, from: Data(contentsOf: url))
        }
        guard let index = latest.firstIndex(where: { $0.id == taskID }),
              let patched = update.applying(to: latest[index].task, expecting: expected) else { return nil }
        latest[index] = DailyTask(id: taskID, task: patched, enabled: latest[index].enabled,
                                  runOnce: latest[index].runOnce)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try PropertyListEncoder().encode(latest).write(to: url, options: .atomic)
        return latest
    }
}

// MARK: - Run-Once Consumption (P03.2 / Q05)

/// Consumption rules for the "run once" switches (Q05). The run snapshot keeps
/// every once switch armed; consumption only happens for a fully successful
/// run's terminal state, never for task-level callbacks, failures or
/// cancellations.
enum DailyRunOnceSemantics {
    /// Only a completed run consumes its once switches: a `runOnce` task is
    /// disabled (the spent flag stays for traceability) and once-only
    /// medicine/stone values are cleared. Every other outcome returns the
    /// list unchanged so the next attempt stays armed. Already-consumed
    /// entries are untouched, making repeated calls idempotent.
    static func consumeOnceTasks(tasks: [DailyTask], outcome: DailyRunOutcome) -> [DailyTask] {
        guard outcome == .completed else { return tasks }
        var consumedAny = false
        let consumed = tasks.map { task -> DailyTask in
            // Disabled tasks never ran in this run; there is nothing to consume.
            guard task.enabled else { return task }
            var next = task
            if task.runOnce {
                next.enabled = false
                consumedAny = true
            }
            if case .fight(var config) = task.task, config.medicineOnce || config.stoneOnce {
                if config.medicineOnce { config.medicine = nil }
                if config.stoneOnce { config.stone = nil }
                // `task` is immutable; rebuild the entry with the cleared values.
                next = DailyTask(id: task.id, task: .fight(config), enabled: next.enabled, runOnce: task.runOnce)
                consumedAny = true
            }
            return next
        }
        return consumedAny ? consumed : tasks
    }
}

/// Persists run-once consumption into the profile a finished run used,
/// routed by profile id so a mid-run profile switch cannot divert the write.
enum DailyRunOnceConsumption {
    /// Read the latest tasks of the run's profile — the live UI list when that
    /// profile is currently selected, the stored file otherwise — consume the
    /// once switches and write the profile back. Returns nil when nothing was
    /// consumable, leaving the stored file untouched; a missing profile file
    /// is never created.
    static func apply(profileID: String, currentTasks: [DailyTask]?, directory: URL) throws -> [DailyTask]? {
        guard !profileID.isEmpty, ![".", ".."].contains(profileID),
              URL(fileURLWithPath: profileID).lastPathComponent == profileID else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let url = directory.appendingPathComponent(profileID).appendingPathExtension("plist")
        var latest: [DailyTask]
        if let currentTasks {
            latest = currentTasks
        } else {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            latest = try PropertyListDecoder().decode([DailyTask].self, from: Data(contentsOf: url))
        }
        let consumed = DailyRunOnceSemantics.consumeOnceTasks(tasks: latest, outcome: .completed)
        guard consumed != latest else { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try PropertyListEncoder().encode(consumed).write(to: url, options: .atomic)
        return consumed
    }
}
