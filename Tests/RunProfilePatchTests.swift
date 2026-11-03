import Foundation

@main struct RunProfilePatchTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ name: String) {
            checks += 1
            if !value { fatalError(name) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("maa-run-profile-patch-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(), otherID = UUID()
        let old = Date(timeIntervalSince1970: 100), event = Date(timeIntervalSince1970: 200), edited = Date(timeIntervalSince1970: 300)
        var mall = MallConfiguration(); mall.creditFightDate = old; mall.friendVisitDate = old; mall.buy_first = ["Original A"]
        let frozen = DailyTask(id: id, task: .mall(mall), enabled: true)
        var clone = mall; clone.buy_first = ["Unrelated B"]; clone.creditFightDate = edited
        let b = [DailyTask(id: id, task: .mall(clone), enabled: false)]
        let aURL = root.appendingPathComponent("A.plist"), bURL = root.appendingPathComponent("B.plist")
        func save(_ value: [DailyTask], _ url: URL) throws { try PropertyListEncoder().encode(value).write(to: url, options: .atomic) }
        func load(_ url: URL) throws -> [DailyTask] { try PropertyListDecoder().decode([DailyTask].self, from: Data(contentsOf: url)) }
        func configure(_ original: DailyTask) throws -> MAAViewModel {
            let model = MAAViewModel(directory: root)
            model.dailyRunTasks = [original]
            model.tasks = b
            model.taskIDMap[42] = id
            let runID = try model.dailyRunCoordinator.begin(profileID: "A", origin: .schedule)!
            try model.dailyRunCoordinator.transition(.running, for: runID)
            return model
        }
        try save([frozen], aURL); try save(b, bURL)
        let bBefore = try Data(contentsOf: bURL)
        let model = try configure(frozen)
        check(model.applyDailyTaskCallback(.creditFightDate(event), coreID: 42), "patch original profile")
        guard case .mall(let saved) = try load(aURL)[0].task else { fatalError() }
        check(saved.creditFightDate == event && saved.buy_first == ["Original A"], "target field changed in A")
        let bAfter = try Data(contentsOf: bURL)
        check(model.tasks == b && bAfter == bBefore, "same UUID clone B untouched")
        guard case .mall(let updatedSnapshot) = model.dailyRunTasks![0].task else { fatalError() }
        check(updatedSnapshot.creditFightDate == event, "snapshot callback field synchronized")
        check(!model.applyDailyTaskCallback(.friendVisitDate(event), coreID: 99), "foreign callback rejected")
        check(!model.applyDailyTaskCallback(.friendVisitDate(event), coreID: nil), "missing task ID rejected")

        var otherEdit = mall; otherEdit.shopping = false; otherEdit.buy_first = ["User edited A"]
        try save([DailyTask(id: id, task: .mall(otherEdit), enabled: false), DailyTask(id: otherID, task: .mall(clone), enabled: true)], aURL)
        let preserving = try configure(frozen)
        check(preserving.applyDailyTaskCallback(.friendVisitDate(event), coreID: 42), "preserve other saved edits")
        let preservedTasks = try load(aURL)
        guard case .mall(let preserved) = preservedTasks[0].task else { fatalError() }
        check(!preserved.shopping && preserved.buy_first == ["User edited A"] && preserved.friendVisitDate == event, "patch only specified field")
        check(!preservedTasks[0].enabled && preservedTasks.count == 2 && preservedTasks[1].id == otherID, "preserve enable and other tasks")
        guard case .mall(let stillFrozen) = preserving.dailyRunTasks![0].task else { fatalError() }
        check(stillFrozen.buy_first == ["Original A"] && stillFrozen.friendVisitDate == event, "snapshot keeps original execution fields")

        var sameFieldEdit = mall; sameFieldEdit.creditFightDate = edited
        try save([DailyTask(id: id, task: .mall(sameFieldEdit), enabled: true)], aURL)
        let conflictBytes = try Data(contentsOf: aURL)
        let conflicting = try configure(frozen)
        check(!conflicting.applyDailyTaskCallback(.creditFightDate(event), coreID: 42), "user same-field edit wins")
        check(try Data(contentsOf: aURL) == conflictBytes, "conflict performs no write")
        check(conflicting.dailyRunTasks == [frozen], "conflict does not advance snapshot")

        let selected = try configure(frozen); selected.dailyTaskProfile = "A"
        selected.tasks = [DailyTask(id: id, task: .mall(otherEdit), enabled: false)]
        check(selected.applyDailyTaskCallback(.creditFightDate(event), coreID: 42), "selected origin uses latest UI")
        guard case .mall(let latestUI) = selected.tasks[0].task else { fatalError() }
        check(latestUI.creditFightDate == event && !latestUI.shopping && latestUI.buy_first == ["User edited A"], "UI preserves other edits")
        check(try load(aURL) == selected.tasks, "origin disk and matching UI synchronized")
        check(!selected.isApplyingDailyCallbackPatch, "write-back suppression released")
        selected.tasks = [DailyTask(id: id, task: .mall(sameFieldEdit), enabled: true)]
        check(!selected.applyDailyTaskCallback(.creditFightDate(.now), coreID: 42), "selected same-field edit respected")

        var infrast = InfrastConfiguration(); infrast.mode = .custom; infrast.filename = "Plan A"; infrast.plan_index = 0
        let infraFrozen = DailyTask(id: id, task: .infrast(infrast), enabled: true)
        var infraEdit = infrast; infraEdit.threshold = 0.75
        try save([DailyTask(id: id, task: .infrast(infraEdit), enabled: true)], aURL)
        let rotation = try configure(infraFrozen)
        check(rotation.applyDailyTaskCallback(.infrastructurePlanIndex(1), coreID: 42), "infrastructure plan advances")
        guard case .infrast(let rotated) = try load(aURL)[0].task else { fatalError() }
        check(rotated.plan_index == 1 && rotated.threshold == 0.75, "rotation preserves user threshold")
        infraEdit.plan_index = 2
        try save([DailyTask(id: id, task: .infrast(infraEdit), enabled: true)], aURL)
        check(!rotation.applyDailyTaskCallback(.infrastructurePlanIndex(2), coreID: 42), "user plan-index edit wins")
        infraEdit.plan_index = 1; infraEdit.filename = "Other plan"
        try save([DailyTask(id: id, task: .infrast(infraEdit), enabled: true)], aURL)
        check(!rotation.applyDailyTaskCallback(.infrastructurePlanIndex(2), coreID: 42), "changed plan file not rotated")
        try FileManager.default.removeItem(at: aURL)
        check(!rotation.applyDailyTaskCallback(.infrastructurePlanIndex(2), coreID: 42), "deleted original profile not recreated")
        check(!FileManager.default.fileExists(atPath: aURL.path), "deleted profile stays deleted")
        try Data("corrupt".utf8).write(to: aURL)
        check(!rotation.applyDailyTaskCallback(.infrastructurePlanIndex(2), coreID: 42), "bad profile not replaced by frozen snapshot")
        check(try Data(contentsOf: aURL) == Data("corrupt".utf8), "bad file preserved for recovery")
        let runID = rotation.dailyRunCoordinator.active!.id
        try rotation.dailyRunCoordinator.transition(.postHook, for: runID)
        check(!rotation.applyDailyTaskCallback(.infrastructurePlanIndex(2), coreID: 42), "late callback after core terminal rejected")

        // R3 regression: rebuild paths must not silently disarm once-only tasks.
        var armedMall = mall; armedMall.buy_first = ["Once only"]
        let armedOnce = DailyTask(id: id, task: .mall(armedMall), enabled: true, runOnce: true)
        try save([armedOnce], aURL)
        let onceModel = try configure(armedOnce)
        check(onceModel.applyDailyTaskCallback(.creditFightDate(event), coreID: 42), "armed once task patched")
        check(try load(aURL)[0].runOnce, "callback patch preserves runOnce on disk")
        check(onceModel.dailyRunTasks![0].runOnce, "callback patch preserves runOnce in the snapshot")
        var onceEdited = armedMall; onceEdited.shopping = false
        onceModel.tasks = [armedOnce]
        onceModel.tasks[id] = .mall(onceEdited)
        guard let afterEdit = onceModel.tasks.first(where: { $0.id == id }) else { fatalError("edited task missing") }
        check(afterEdit.runOnce, "subscript edit preserves runOnce")

        // R3 Q1 regression: the production finishDailyRun consumes once-only
        // tasks only when the run's own terminal completes, and keeps them
        // armed on cancellation (hook exercised on the extracted body).
        let hookURL = root.appendingPathComponent("Hook.plist")
        let hookModel = MAAViewModel(directory: root)
        var hookMall = mall; hookMall.buy_first = ["Hook armed"]
        let hookArmed = DailyTask(id: id, task: .mall(hookMall), enabled: true, runOnce: true)
        try save([hookArmed], hookURL)
        hookModel.tasks = [hookArmed]
        hookModel.dailyTaskProfile = "Hook"
        let hookRun = try hookModel.dailyRunCoordinator.begin(profileID: "Hook", origin: .schedule)!
        try hookModel.dailyRunCoordinator.transition(.running, for: hookRun)
        await hookModel.finishDailyRun(hookRun, outcome: .cancelled, preparationCleanupSucceeded: true)
        let cancelledDisk = try load(hookURL)
        check(cancelledDisk[0].runOnce && cancelledDisk[0].enabled,
              "cancelled finish keeps once armed on disk")
        check(hookModel.tasks[0].runOnce && hookModel.tasks[0].enabled,
              "cancelled finish keeps the live list armed")
        let hookRun2 = try hookModel.dailyRunCoordinator.begin(profileID: "Hook", origin: .schedule)!
        try hookModel.dailyRunCoordinator.transition(.running, for: hookRun2)
        await hookModel.finishDailyRun(hookRun2, outcome: .completed, preparationCleanupSucceeded: true)
        // Consumption disables the once task; the spent runOnce flag stays for
        // traceability (same contract as the once-only medicine/stone path).
        let consumedDisk = try load(hookURL)
        check(consumedDisk[0].runOnce && !consumedDisk[0].enabled,
              "completed finish consumes the armed task on disk")
        check(hookModel.tasks[0].runOnce && !hookModel.tasks[0].enabled,
              "completed finish consumes the live list")

        // P03.2 multi-profile registry: after switching the active pointer away,
        // a run's callback patch still lands on the profile it ran against.
        let multiRoot = FileManager.default.temporaryDirectory.appendingPathComponent("maa-multi-profile-\(UUID())")
        try FileManager.default.createDirectory(at: multiRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: multiRoot) }
        let registry = ProfileStore(rootURL: multiRoot)
        let alt = try registry.create(name: "小号")
        try registry.saveTasks(profileID: ProfileStore.defaultProfileID, tasks: [frozen])
        try registry.saveTasks(profileID: alt.id, tasks: [DailyTask(id: otherID, task: .mall(mall), enabled: true)])
        try registry.setActive(alt.id)
        let altBytes = try Data(contentsOf: multiRoot.appendingPathComponent("\(alt.id).plist"))
        let multi = MAAViewModel(directory: multiRoot)
        multi.dailyRunTasks = [frozen]
        multi.taskIDMap[7] = id
        let multiRun = try multi.dailyRunCoordinator.begin(
            profileID: ProfileStore.defaultProfileID, origin: .schedule)!
        try multi.dailyRunCoordinator.transition(.running, for: multiRun)
        check(multi.applyDailyTaskCallback(.creditFightDate(event), coreID: 7), "multi-profile patch applies")
        guard case .mall(let multiSaved) = try load(multiRoot.appendingPathComponent("Default.plist"))[0].task else { fatalError() }
        check(multiSaved.creditFightDate == event, "patch lands on run profile despite active switch")
        check(try Data(contentsOf: multiRoot.appendingPathComponent("\(alt.id).plist")) == altBytes, "other registry profile untouched")

        // P03.2 / Q05 run-once semantics: pure consumption rules.
        let onceRoot = FileManager.default.temporaryDirectory.appendingPathComponent("maa-run-once-\(UUID())")
        try FileManager.default.createDirectory(at: onceRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: onceRoot) }
        func armedFight(medicine: Int?, stone: Int?, medicineOnce: Bool = false, stoneOnce: Bool = false) -> FightConfiguration {
            var config = FightConfiguration()
            config.medicine = medicine
            config.stone = stone
            config.medicineOnce = medicineOnce
            config.stoneOnce = stoneOnce
            return config
        }
        let runOnceID = UUID(), fightID = UUID()
        let armedTasks: [DailyTask] = [
            DailyTask(id: runOnceID, task: .mall(mall), enabled: true, runOnce: true),
            DailyTask(id: fightID, task: .fight(armedFight(medicine: 3, stone: 2, medicineOnce: true, stoneOnce: true)), enabled: true),
            DailyTask(id: UUID(), task: .fight(armedFight(medicine: 3, stone: 2)), enabled: true),
            DailyTask(id: UUID(), task: .mall(mall), enabled: false, runOnce: true),
        ]
        let consumedTasks = DailyRunOnceSemantics.consumeOnceTasks(tasks: armedTasks, outcome: .completed)
        check(consumedTasks[0].enabled == false && consumedTasks[0].runOnce == true, "runOnce task disabled, flag kept for traceability")
        check(consumedTasks[1].enabled == true, "once-only fight task stays enabled")
        if case .fight(let consumedFight) = consumedTasks[1].task {
            check(consumedFight.medicine == nil && consumedFight.stone == nil
                && consumedFight.medicineOnce && consumedFight.stoneOnce, "once-only medicine/stone cleared, flags kept")
        } else { fatalError() }
        check(consumedTasks[2] == armedTasks[2], "plain fight untouched")
        check(consumedTasks[3] == armedTasks[3], "already-disabled once task untouched")
        for badOutcome in [DailyRunOutcome.failed, .cancelled, .interrupted] {
            check(DailyRunOnceSemantics.consumeOnceTasks(tasks: armedTasks, outcome: badOutcome) == armedTasks,
                  "non-success outcome \(badOutcome.rawValue) stays armed")
        }
        check(DailyRunOnceSemantics.consumeOnceTasks(tasks: consumedTasks, outcome: .completed) == consumedTasks,
              "repeated consumption is idempotent")

        // Legacy plists without the new keys decode the once switches as false.
        // (Enum payloads are stored positionally under "_0", matching the
        // production plists written by PropertyListEncoder.)
        let legacyRecord: [String: Any] = [
            "id": UUID().uuidString,
            "task": ["fight": ["_0": ["stage": "1-7", "medicine": 3, "stone": 1, "medicine_expire_days": 2]]],
            "enabled": true,
        ]
        let legacyData = try PropertyListSerialization.data(fromPropertyList: [legacyRecord], format: .binary, options: 0)
        let legacyTasks = try PropertyListDecoder().decode([DailyTask].self, from: legacyData)
        check(legacyTasks[0].runOnce == false, "legacy plist without runOnce decodes false")
        if case .fight(let legacyFight) = legacyTasks[0].task {
            check(!legacyFight.medicineOnce && !legacyFight.stoneOnce, "legacy fight decodes once flags as false")
            check(legacyFight.medicine == 3 && legacyFight.stone == 1, "legacy values preserved")
        } else { fatalError() }
        check(try PropertyListDecoder().decode([DailyTask].self, from: PropertyListEncoder().encode(consumedTasks)) == consumedTasks,
              "runOnce round-trips through the plist codec")

        // Consumption routes into the run's profile file on disk.
        let armedURL = onceRoot.appendingPathComponent("A.plist")
        let selectedURL = onceRoot.appendingPathComponent("B.plist")
        func armDiskProfiles() throws {
            try PropertyListEncoder().encode(armedTasks).write(to: armedURL, options: .atomic)
            try PropertyListEncoder().encode([DailyTask(id: UUID(), task: .mall(mall), enabled: true)])
                .write(to: selectedURL, options: .atomic)
        }
        try armDiskProfiles()
        let selectedBytes = try Data(contentsOf: selectedURL)
        guard let routed = try DailyRunOnceConsumption.apply(profileID: "A", currentTasks: nil, directory: onceRoot) else {
            fatalError("armed profile must consume")
        }
        check(routed == (try load(armedURL)), "routed result matches the stored profile")
        if case .fight(let routedFight) = try load(armedURL)[1].task {
            check(routedFight.medicine == nil && routedFight.stone == nil, "disk profile consumed")
        } else { fatalError() }
        check(try Data(contentsOf: selectedURL) == selectedBytes, "other profile untouched by consumption")
        check(try DailyRunOnceConsumption.apply(profileID: "A", currentTasks: nil, directory: onceRoot) == nil,
              "second consumption is a no-op")
        check(try DailyRunOnceConsumption.apply(profileID: "C", currentTasks: nil, directory: onceRoot) == nil,
              "unknown profile yields no consumption")
        check(!FileManager.default.fileExists(atPath: onceRoot.appendingPathComponent("C.plist").path),
              "consumption never creates a profile")

        // The production terminal hook: only a full terminal state consumes.
        let terminal = MAAViewModel(directory: onceRoot)
        terminal.dailyTaskProfile = "A"
        terminal.tasks = armedTasks
        let terminalRun = try terminal.dailyRunCoordinator.begin(profileID: "A", origin: .schedule)!
        try terminal.dailyRunCoordinator.transition(.running, for: terminalRun)
        try terminal.dailyRunCoordinator.finish(terminalRun, outcome: .completed, cleanupSucceeded: true)
        terminal.consumeRunOnceSemantics(terminal: terminal.dailyRunCoordinator.lastTerminal!)
        check(terminal.tasks[0].enabled == false && terminal.tasks[3].enabled == false, "terminal success updates the live UI list")
        if case .fight(let liveFight) = terminal.tasks[1].task {
            check(liveFight.medicine == nil && liveFight.stone == nil, "live once-only values cleared")
        } else { fatalError() }
        check(try load(armedURL) == terminal.tasks, "terminal success persists to the run profile")

        for badOutcome in [DailyRunOutcome.failed, .cancelled] {
            let unfinished = MAAViewModel(directory: onceRoot)
            unfinished.dailyTaskProfile = "A"
            unfinished.tasks = armedTasks
            try armDiskProfiles()
            let badRun = try unfinished.dailyRunCoordinator.begin(profileID: "A", origin: .manual)!
            try unfinished.dailyRunCoordinator.finish(badRun, outcome: badOutcome, cleanupSucceeded: true)
            unfinished.consumeRunOnceSemantics(terminal: unfinished.dailyRunCoordinator.lastTerminal!)
            check(unfinished.tasks == armedTasks, "\(badOutcome.rawValue) terminal does not consume the live list")
            check(try load(armedURL) == armedTasks, "\(badOutcome.rawValue) terminal does not consume the disk profile")
        }

        // A late terminal callback for a superseded runID must not consume.
        let late = MAAViewModel(directory: onceRoot)
        late.dailyTaskProfile = "A"
        late.tasks = armedTasks
        try armDiskProfiles()
        let staleRun = try late.dailyRunCoordinator.begin(profileID: "A", origin: .schedule)!
        try late.dailyRunCoordinator.finish(staleRun, outcome: .completed, cleanupSucceeded: true)
        let staleTerminal = late.dailyRunCoordinator.lastTerminal!
        let newerRun = try late.dailyRunCoordinator.begin(profileID: "A", origin: .manual)!
        try late.dailyRunCoordinator.finish(newerRun, outcome: .completed, cleanupSucceeded: true)
        late.consumeRunOnceSemantics(terminal: staleTerminal)
        check(late.tasks == armedTasks, "late terminal with a stale runID is rejected")
        check(try load(armedURL) == armedTasks, "stale runID writes nothing")

        // A claimed terminal while the run is still active is equally rejected.
        let active = MAAViewModel(directory: onceRoot)
        active.dailyTaskProfile = "A"
        active.tasks = armedTasks
        let activeRun = try active.dailyRunCoordinator.begin(profileID: "A", origin: .hotkey)!
        try active.dailyRunCoordinator.transition(.running, for: activeRun)
        let fabricated = RunContext(id: activeRun, origin: .hotkey, profileID: "A",
                                     status: .finished, startedAt: .now, finishedAt: .now,
                                     outcome: .completed, cleanupSucceeded: true)
        active.consumeRunOnceSemantics(terminal: fabricated)
        check(active.tasks == armedTasks, "terminal for a still-active run is rejected")

        // Running against a non-selected profile consumes only that profile.
        let cross = MAAViewModel(directory: onceRoot)
        cross.dailyTaskProfile = "B"
        cross.tasks = [DailyTask(id: UUID(), task: .mall(mall), enabled: true)]
        let crossRun = try cross.dailyRunCoordinator.begin(profileID: "A", origin: .schedule)!
        try cross.dailyRunCoordinator.finish(crossRun, outcome: .completed, cleanupSucceeded: true)
        cross.consumeRunOnceSemantics(terminal: cross.dailyRunCoordinator.lastTerminal!)
        check(cross.tasks.count == 1 && cross.tasks[0].runOnce == false, "selected other-profile UI untouched")
        check(try load(armedURL) == DailyRunOnceSemantics.consumeOnceTasks(tasks: armedTasks, outcome: .completed),
              "run profile consumed even while another profile is selected")
        print("RunProfilePatchTests: \(checks) assertions passed")
    }
}
