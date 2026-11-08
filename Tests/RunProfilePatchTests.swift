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
        // P08.3: choosing fixed during a run wins over its late automatic callback.
        var fixedEdit = infrast; fixedEdit.planSelection = .fixed
        try save([DailyTask(id: id, task: .infrast(fixedEdit), enabled: true)], aURL)
        let switched = try configure(infraFrozen)
        let fixedBefore = try Data(contentsOf: aURL)
        check(!switched.applyDailyTaskCallback(.infrastructurePlanIndex(1), coreID: 42), "late automatic callback respects fixed selection")
        check(try Data(contentsOf: aURL) == fixedBefore, "fixed selection stays byte-identical on disk")
        let fixedFrozen = DailyTask(id: id, task: .infrast(fixedEdit), enabled: true)
        let fixedRun = try configure(fixedFrozen)
        check(!fixedRun.applyDailyTaskCallback(.infrastructurePlanIndex(1), coreID: 42), "fixed run never advances on success")
        try save([infraFrozen], aURL)
        check(!fixedRun.applyDailyTaskCallback(.infrastructurePlanIndex(1), coreID: 42), "fixed run cannot rotate a profile switched back to automatic")
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
        // armed on cancellation (hook exercised on the extracted body). Since
        // P03.3/N1 the consumption scope is the frozen run snapshot, so the
        // armed task must ride in dailyRunTasks too.
        let hookURL = root.appendingPathComponent("Hook.plist")
        let hookModel = MAAViewModel(directory: root)
        var hookMall = mall; hookMall.buy_first = ["Hook armed"]
        let hookArmed = DailyTask(id: id, task: .mall(hookMall), enabled: true, runOnce: true)
        try save([hookArmed], hookURL)
        hookModel.tasks = [hookArmed]
        hookModel.dailyTaskProfile = "Hook"
        let hookRun = try hookModel.dailyRunCoordinator.begin(profileID: "Hook", origin: .schedule)!
        try hookModel.dailyRunCoordinator.transition(.running, for: hookRun)
        hookModel.dailyRunTasks = [hookArmed]
        await hookModel.finishDailyRun(hookRun, outcome: .cancelled, preparationCleanupSucceeded: true)
        let cancelledDisk = try load(hookURL)
        check(cancelledDisk[0].runOnce && cancelledDisk[0].enabled,
              "cancelled finish keeps once armed on disk")
        check(hookModel.tasks[0].runOnce && hookModel.tasks[0].enabled,
              "cancelled finish keeps the live list armed")
        let hookRun2 = try hookModel.dailyRunCoordinator.begin(profileID: "Hook", origin: .schedule)!
        try hookModel.dailyRunCoordinator.transition(.running, for: hookRun2)
        hookModel.dailyRunTasks = [hookArmed]
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

        // N1 (P03.3): consumption is scoped to the run's frozen snapshot —
        // entries armed after the snapshot froze never executed and stay armed.
        let outsider = DailyTask(id: UUID(), task: .mall(mall), enabled: true, runOnce: true)
        let snapshotIDs = Set(armedTasks.filter(\.enabled).map(\.id))
        let withOutsider = armedTasks + [outsider]
        let scoped = DailyRunOnceSemantics.consumeOnceTasks(
            tasks: withOutsider, outcome: .completed, eligibleIDs: snapshotIDs)
        check(scoped[0].enabled == false, "snapshot runOnce task consumed under scope")
        if case .fight(let scopedFight) = scoped[1].task {
            check(scopedFight.medicine == nil && scopedFight.stone == nil, "snapshot once-only fight consumed under scope")
        } else { fatalError() }
        check(scoped[4].enabled == true && scoped[4].runOnce, "mid-run armed once task stays armed")
        check(DailyRunOnceSemantics.consumeOnceTasks(tasks: armedTasks, outcome: .completed)
              == DailyRunOnceSemantics.consumeOnceTasks(tasks: armedTasks, outcome: .completed, eligibleIDs: snapshotIDs),
              "nil scope equals the snapshot-id scope on the snapshot list itself")

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
        terminal.dailyRunTasks = armedTasks  // 运行期冻结的快照（N1 消费范围）
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
        cross.dailyRunTasks = armedTasks  // A 的冻结快照（N1 消费范围）
        let crossRun = try cross.dailyRunCoordinator.begin(profileID: "A", origin: .schedule)!
        try cross.dailyRunCoordinator.finish(crossRun, outcome: .completed, cleanupSucceeded: true)
        cross.consumeRunOnceSemantics(terminal: cross.dailyRunCoordinator.lastTerminal!)
        check(cross.tasks.count == 1 && cross.tasks[0].runOnce == false, "selected other-profile UI untouched")
        check(try load(armedURL) == DailyRunOnceSemantics.consumeOnceTasks(tasks: armedTasks, outcome: .completed),
              "run profile consumed even while another profile is selected")

        // N1 (P03.3) 端到端：快照里只有 runOnce 任务；运行中新武装的 once
        // 任务（最新列表/磁盘都有）终态不被消费，快照内的照常消费。
        let n1 = MAAViewModel(directory: onceRoot)
        n1.dailyTaskProfile = "A"
        n1.dailyRunTasks = [armedTasks[0]]  // 快照冻结时仅含 runOnce 任务
        var midRunArmed = armedTasks
        midRunArmed.append(DailyTask(id: UUID(), task: .fight(armedFight(medicine: 5, stone: nil, medicineOnce: true)), enabled: true))
        n1.tasks = midRunArmed
        try PropertyListEncoder().encode(midRunArmed).write(to: armedURL, options: .atomic)
        let n1Run = try n1.dailyRunCoordinator.begin(profileID: "A", origin: .schedule)!
        try n1.dailyRunCoordinator.transition(.running, for: n1Run)
        try n1.dailyRunCoordinator.finish(n1Run, outcome: .completed, cleanupSucceeded: true)
        n1.consumeRunOnceSemantics(terminal: n1.dailyRunCoordinator.lastTerminal!)
        let n1Saved = try load(armedURL)
        check(n1Saved[0].enabled == false, "snapshot runOnce task consumed")
        if case .fight(let n1Fight) = n1Saved[4].task {
            check(n1Saved[4].enabled == true && n1Fight.medicine == 5 && n1Fight.medicineOnce,
                  "mid-run armed once task stays armed on disk")
        } else { fatalError() }
        check(n1.tasks == n1Saved, "live list mirrors the snapshot-scoped consumption")

        // P03.3 切档隔离：程序化 switchProfile 在运行中被拒（UI 禁用只是
        // 第一层防线）；运行中编辑另一档案不影响进行中运行的回写目标——
        // 回写按 runID 所属档案路由的断言见上文 multi-profile 段，这里补
        // "编辑非运行档案后，回写仍落运行时档案且不污染冻结快照"。
        let isoRoot = FileManager.default.temporaryDirectory.appendingPathComponent("maa-profile-switch-iso-\(UUID())")
        try FileManager.default.createDirectory(at: isoRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: isoRoot) }
        let isoRegistry = ProfileStore(rootURL: isoRoot)
        let isoAlt = try isoRegistry.create(name: "小号")
        try isoRegistry.saveTasks(profileID: ProfileStore.defaultProfileID, tasks: [frozen])
        var isoAltConfig = mall; isoAltConfig.shopping = false
        let isoAltTasks = [DailyTask(id: otherID, task: .mall(isoAltConfig), enabled: true)]
        try isoRegistry.saveTasks(profileID: isoAlt.id, tasks: isoAltTasks)
        try isoRegistry.setActive(isoAlt.id)
        let iso = MAAViewModel(directory: isoRoot)
        iso.dailyTaskProfile = isoAlt.id  // UI 停在小号；init 的指针同步是 P03.2 行为，此处直设
        iso.tasks = isoAltTasks
        iso.taskIDMap[9] = id
        iso.dailyRunTasks = [frozen]  // 调度快照：Default 的冻结任务
        let isoRun = try iso.dailyRunCoordinator.begin(
            profileID: ProfileStore.defaultProfileID, origin: .schedule)!
        try iso.dailyRunCoordinator.transition(.running, for: isoRun)

        // 运行中程序化切换被拒：UI 档案、active 指针、任务列表均不动。
        iso.switchProfile(ProfileStore.defaultProfileID)
        check(iso.dailyTaskProfile == isoAlt.id, "mid-run programmatic switch refused: UI profile stays")
        check(try isoRegistry.activeProfileID() == isoAlt.id, "mid-run switch refused: active pointer stays")
        check(iso.tasks == isoAltTasks, "mid-run switch refused: task list stays")

        // 运行中编辑非运行档案（小号）后，回调回写仍落运行时档案（Default）。
        var isoAltEdited = mall; isoAltEdited.shopping = false
        let isoAltEditedTasks = [DailyTask(id: otherID, task: .mall(isoAltEdited), enabled: false)]
        try isoRegistry.saveTasks(profileID: isoAlt.id, tasks: isoAltEditedTasks)
        check(iso.applyDailyTaskCallback(.creditFightDate(event), coreID: 9), "callback applies after other-profile edit")
        guard case .mall(let isoSaved) = try load(isoRoot.appendingPathComponent("Default.plist"))[0].task else { fatalError() }
        check(isoSaved.creditFightDate == event && isoSaved.buy_first == ["Original A"],
              "write-back still lands on the run's profile")
        check(try load(isoRoot.appendingPathComponent("\(isoAlt.id).plist")) == isoAltEditedTasks,
              "mid-run edit of the other profile preserved")
        guard case .mall(let isoFrozen) = iso.dailyRunTasks![0].task else { fatalError() }
        check(isoFrozen.buy_first == ["Original A"] && isoFrozen.creditFightDate == event,
              "frozen snapshot untouched by the other-profile edit")
        check(iso.tasks == isoAltTasks, "selected profile's UI list untouched by the run's write-back")

        // 收口窗口防御：运行已终态但冻结快照尚存时，切换同样被拒。
        try iso.dailyRunCoordinator.finish(isoRun, outcome: .completed, cleanupSucceeded: true)
        iso.status = .idle  // finishDailyRun 收口后的正常状态
        iso.switchProfile(ProfileStore.defaultProfileID)
        check(iso.dailyTaskProfile == isoAlt.id, "switch refused while a frozen snapshot is still live")
        iso.dailyRunTasks = nil  // 生产中由 finishDailyRun 清空
        iso.switchProfile(ProfileStore.defaultProfileID)
        check(iso.dailyTaskProfile == ProfileStore.defaultProfileID, "switch proceeds once the run fully closed")
        check(try load(isoRoot.appendingPathComponent("Default.plist")) == iso.tasks,
              "switch loads the target profile's stored tasks")
        // P11.3: scope-bound receipts patch the run's source profile, never a
        // same-ID clone or a user's mid-run frequency/selection edit.
        do {
            var update = UserDataUpdateConfiguration()
            update.triggerInterval = .daily
            let ownerScope = InventoryScope(connection: "adb", server: "CN", profile: "A", account: "account")
            let depotReceipt = UserDataSyncReceipt(scope: ownerScope, completedAt: event)
            let operatorReceipt = UserDataSyncReceipt(scope: ownerScope, completedAt: edited)
            let original = DailyTask(id: id, task: .userdataupdate(update), enabled: true, runOnce: true)
            try save([original], aURL)
            let refresh = try configure(original)
            check(refresh.applyDailyTaskCallback(.userDataSync(.depot, depotReceipt), coreID: 42), "successful depot updates source profile receipt")
            guard case .userdataupdate(let depotSaved) = try load(aURL)[0].task else { fatalError() }
            check(depotSaved.lastDepotSync == depotReceipt && depotSaved.lastOperBoxSync == nil, "one data kind does not premark another")
            check(try load(aURL)[0].runOnce && load(aURL)[0].enabled, "receipt patch preserves runOnce and enabled")
            check(try refresh.tasks == b && Data(contentsOf: bURL) == bBefore, "receipt cannot update selected clone profile")
            check(refresh.applyDailyTaskCallback(.userDataSync(.operBox, operatorReceipt), coreID: 42), "second successful kind patches independently")
            guard case .userdataupdate(let bothSaved) = try load(aURL)[0].task else { fatalError() }
            check(bothSaved.lastDepotSync == depotReceipt && bothSaved.lastOperBoxSync == operatorReceipt, "both success receipts retained")

            var frequencyEdit = update; frequencyEdit.triggerInterval = .weekly
            try save([DailyTask(id: id, task: .userdataupdate(frequencyEdit), enabled: true)], aURL)
            let beforeFrequency = try Data(contentsOf: aURL)
            let stale = try configure(original)
            check(!stale.applyDailyTaskCallback(.userDataSync(.depot, depotReceipt), coreID: 42), "user frequency edit wins over late receipt")
            check(try Data(contentsOf: aURL) == beforeFrequency, "frequency edit remains byte-identical")
            var deselected = update; deselected.updateDepot = false
            try save([DailyTask(id: id, task: .userdataupdate(deselected), enabled: true)], aURL)
            check(!stale.applyDailyTaskCallback(.userDataSync(.depot, depotReceipt), coreID: 42), "user deselection wins")
            var otherSelection = update; otherSelection.updateOperBox = false
            try save([DailyTask(id: id, task: .userdataupdate(otherSelection), enabled: true)], aURL)
            check(stale.applyDailyTaskCallback(.userDataSync(.depot, depotReceipt), coreID: 42), "unrelated data selection preserved while selected kind updates")
            guard case .userdataupdate(let partialSelection) = try load(aURL)[0].task else { fatalError() }
            check(!partialSelection.updateOperBox, "callback does not restore user's other toggle")

            try save([original], aURL)
            let foreignScope = InventoryScope(connection: "adb", server: "CN", profile: "B", account: "account")
            let originalBytes = try Data(contentsOf: aURL)
            let foreign = try configure(original)
            check(!foreign.applyDailyTaskCallback(.userDataSync(.depot, .init(scope: foreignScope, completedAt: event)), coreID: 42), "receipt profile must match journal source profile")
            let unbound = InventoryScope(connection: "adb", server: "CN", profile: "A")
            check(!foreign.applyDailyTaskCallback(.userDataSync(.depot, .init(scope: unbound, completedAt: event)), coreID: 42), "anonymous receipt cannot suppress a later refresh")
            check(!foreign.applyDailyTaskCallback(.userDataSync(.depot, .init(scope: ownerScope, completedAt: Date(timeIntervalSince1970: -1e100))), coreID: 42), "malformed receipt clock rejected")
            check(try Data(contentsOf: aURL) == originalBytes, "rejected identity/clock writes leave source profile unchanged")
            let active = foreign.dailyRunCoordinator.active!.id
            try foreign.dailyRunCoordinator.finish(active, outcome: .completed, cleanupSucceeded: true)
            check(!foreign.applyDailyTaskCallback(.userDataSync(.depot, depotReceipt), coreID: 42), "late terminal receipt refused after run ownership released")
        }
        print("RunProfilePatchTests: \(checks) assertions passed")
    }
}
