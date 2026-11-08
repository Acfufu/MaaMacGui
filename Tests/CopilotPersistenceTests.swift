import Darwin
import Foundation

// Exercise the copilot persistence layer (C09): configuration/list-state
// round-trips, corrupted-store tolerance, override application with stable
// member keys, set listing member-skip recovery, and the restore flow through
// CopilotContext. Production CopilotConfiguration.swift / CopilotPersistence.swift
// / MAACopilot.swift are compiled verbatim; only external boundaries
// (Defaults, MAAProvider, MAATaskType, externalCopilotDirectory) are stubbed
// by the script — the stubbed MAAProvider maps stage names identically.

@main
struct CopilotPersistenceTests {
    static func main() async throws {
        // Unbuffered stdout: a crash must not discard already-printed progress.
        setvbuf(stdout, nil, _IONBF, 0)

        let suite = "MAACopilotPersistenceTests-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }
        CopilotPersistence.store = store

        var failures = [String]()
        var checkIndex = 0
        func check(_ condition: Bool, _ label: String) {
            checkIndex += 1
            if condition {
                print("PASS[\(checkIndex)]: \(label)")
            } else {
                failures.append(label)
                print("FAIL[\(checkIndex)]: \(label)")
            }
        }
        func clearStore() {
            store.removeObject(forKey: "CopilotConfigurationState")
            store.removeObject(forKey: "CopilotListState")
        }

        func normalizedPath(_ url: URL?) -> String {
            guard var path = url?.path(percentEncoded: false) else { return "" }
            while path.count > 1 && path.hasSuffix("/") {
                path.removeLast()
            }
            return path
        }

        let regularJSON = #"{"stage_name":"1-7","opers":[],"minimum_required":"v4.0"}"#
        let sssJSON = #"{"stage_name":"SSS_1","opers":[],"minimum_required":"v4.0","type":"SSS"}"#
        let paradoxJSON = #"{"stage_name":"mem_test","opers":[],"minimum_required":"v4.0"}"#

        func makeSetDirectory(name: String, ids: [Int], contents: [Int: String]) throws -> URL {
            let dir = FileManager.default.temporaryDirectory
                .appending(path: "copilot-persist-fixture-\(UUID().uuidString)")
                .appending(path: name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let meta: [String: Any] = ["name": name, "description": "d", "copilot_ids": ids]
            try JSONSerialization.data(withJSONObject: meta)
                .write(to: dir.appending(path: ".\(name).json"))
            for (id, json) in contents {
                try Data(json.utf8).write(to: dir.appending(path: "\(id).json"))
            }
            return dir
        }

        // MARK: - A. Configuration persistence

        clearStore()
        check(CopilotPersistence.loadConfiguration() == nil, "missing configuration archive reads as nil")

        var config = CopilotConfiguration()
        config.loop_times = 3
        config.formation = true
        config.formation_index = 2
        config.use_sanity_potion = true
        config.support_unit_usage = .specific
        config.support_unit_name = "Exusiai"
        config.add_trust = true
        config.ignore_requirements = true
        config.user_additional = [.init(name: "Amiya", skill: 3)]
        CopilotPersistence.saveConfiguration(config)
        check(CopilotPersistence.loadConfiguration() == config, "configuration round-trips through the store")

        store.set(Data("corrupt".utf8), forKey: "CopilotConfigurationState")
        check(CopilotPersistence.loadConfiguration() == nil, "corrupted configuration archive reads as nil")

        // MARK: - B. List state persistence

        clearStore()
        check(CopilotPersistence.loadListState() == nil, "missing list state reads as nil")

        var state = CopilotListState(
            setPath: "/tmp/set", order: ["102#0", "101#0"],
            overrides: [
                "101#0": .init(isOn: false, isRaid: true, navOverride: "AC-5"),
                "102#0": .init(isOn: true, isRaid: nil, navOverride: nil),
            ])
        CopilotPersistence.saveListState(state)
        check(CopilotPersistence.loadListState() == state, "list state round-trips through the store")

        store.set(Data("corrupt".utf8), forKey: "CopilotListState")
        check(CopilotPersistence.loadListState() == nil, "corrupted list state reads as nil")

        // MARK: - C. Capture / apply transforms

        let base = URL(fileURLWithPath: "/tmp/copilot-test")
        func row(_ id: String, isRaid: Bool?, isOn: Bool, nav: String? = nil) -> CopilotContext.ListItem {
            .init(url: base.appending(path: "\(id).json"), stageCode: "S", memberID: id, isRaid: isRaid, isOn: isOn, navOverride: nav)
        }

        let live = [row("101#0", isRaid: nil, isOn: true), row("101#1", isRaid: true, isOn: true), row("102#0", isRaid: false, isOn: false, nav: "1-7")]
        let captured = CopilotPersistence.capture(items: live, setURL: base.appending(path: "s1"))
        let refreshed = [row("101#0", isRaid: nil, isOn: true), row("101#1", isRaid: true, isOn: true), row("102#0", isRaid: false, isOn: true)]
        let reApplied = CopilotPersistence.apply(captured, to: refreshed)
        check(reApplied.map(\.memberID) == ["101#0", "101#1", "102#0"], "capture→apply preserves member order")
        check(reApplied.map(\.isOn) == [true, true, false], "capture→apply preserves checked state")
        check(reApplied.map(\.navOverride) == [nil, nil, "1-7"], "capture→apply preserves nav overrides")

        let overrideState = CopilotListState(
            setPath: nil, order: [],
            overrides: ["101#0": .init(isOn: false, isRaid: true, navOverride: "AC-5")])
        let overridden = CopilotPersistence.apply(overrideState, to: [row("101#0", isRaid: nil, isOn: true), row("102#0", isRaid: nil, isOn: true)])
        check(overridden[0].isOn == false && overridden[0].isRaid == true && overridden[0].navOverride == "AC-5", "override applies isOn/isRaid/navOverride")
        check(overridden[1].isOn == true && overridden[1].isRaid == nil && overridden[1].navOverride == nil, "rows without an override keep listing defaults")

        let reversed = CopilotPersistence.apply(
            CopilotListState(setPath: nil, order: ["102#0", "101#0"], overrides: [:]),
            to: [row("101#0", isRaid: nil, isOn: true), row("102#0", isRaid: nil, isOn: true)])
        check(reversed.map(\.memberID) == ["102#0", "101#0"], "order reverses execution order")

        let appended = CopilotPersistence.apply(
            CopilotListState(setPath: nil, order: ["102#0"], overrides: [:]),
            to: [row("101#0", isRaid: nil, isOn: true), row("102#0", isRaid: nil, isOn: true)])
        check(appended.map(\.memberID) == ["102#0", "101#0"], "rows missing from order append after ordered ones")

        let unknownOnly = CopilotPersistence.apply(
            CopilotListState(setPath: nil, order: ["999#0", "888#0"], overrides: [:]),
            to: [row("102#0", isRaid: nil, isOn: true), row("101#0", isRaid: nil, isOn: true)])
        check(unknownOnly.map(\.memberID) == ["102#0", "101#0"], "order with only unknown keys keeps listing order")

        // MARK: - D. Set listing member-skip recovery

        let fixture1 = try makeSetDirectory(
            name: "t1", ids: [101, 102, 103],
            contents: [101: regularJSON, 102: "{ broken"])
        let listing1 = await CopilotSetData(atDirectory: fixture1)!.copilotList(at: fixture1)
        check(listing1 != nil, "listing survives partially broken members")
        check(listing1?.items.count == 1 && listing1?.items[0].memberID == "101#0", "only parseable members become rows")
        check(listing1?.skipped.count == 2, "both broken members reported")
        check(listing1?.skipped.contains(where: { $0.contains("102.json") && $0.contains("文件损坏") }) == true, "corrupt member reason")
        check(listing1?.skipped.contains(where: { $0.contains("103.json") && $0.contains("文件缺失") }) == true, "missing member reason")
        check(listing1?.kind == .regular, "kind derives from surviving member")

        let fixture2 = try makeSetDirectory(name: "t2", ids: [201, 202], contents: [201: "{ broken", 202: "{ broken"])
        check(await CopilotSetData(atDirectory: fixture2)!.copilotList(at: fixture2) == nil, "listing fails when every member is broken")

        let fixture3 = try makeSetDirectory(name: "t3", ids: [301, 302], contents: [301: regularJSON, 302: sssJSON])
        check(await CopilotSetData(atDirectory: fixture3)!.copilotList(at: fixture3) == nil, "mixed-kind listing still rejected")

        let fixture4 = try makeSetDirectory(name: "t4", ids: [], contents: [:])
        let listing4 = await CopilotSetData(atDirectory: fixture4)!.copilotList(at: fixture4)
        check(listing4?.kind == .regular && listing4?.items.isEmpty == true && listing4?.skipped.isEmpty == true, "empty id list keeps regular-empty listing")

        let twinJSON = #"{"stage_name":"1-7","opers":[],"minimum_required":"v4.0","difficulty":3}"#
        let fixture5 = try makeSetDirectory(name: "t5", ids: [401], contents: [401: twinJSON])
        let listing5 = await CopilotSetData(atDirectory: fixture5)!.copilotList(at: fixture5)
        check(listing5?.items.map(\.memberID) == ["401#0", "401#1"], "difficulty-3 twin rows carry distinct member keys")
        check(listing5?.items.map(\.isRaid) == [false, true], "twin rows derive raid flags")
        check(listing5?.items.map(\.isOn) == [true, true], "twin rows default checked")

        let paradoxTwin = #"{"stage_name":"mem_test","opers":[],"minimum_required":"v4.0","difficulty":2}"#
        let fixture6 = try makeSetDirectory(name: "t6", ids: [402], contents: [402: paradoxTwin])
        let listing6 = await CopilotSetData(atDirectory: fixture6)!.copilotList(at: fixture6)
        check(
            listing6?.kind == .paradox
                && listing6?.items.map(\.memberID) == ["402#1"]
                && listing6?.items.map(\.isRaid) == [true]
                && listing6?.items.map(\.isOn) == [true]
                && listing6?.items.map(\.stageCode) == ["mem_test"],
            "paradox raid row keyed and kinded")

        // MARK: - E. Restore flow through CopilotContext

        clearStore()
        let context1 = CopilotContext()
        check(context1.config == CopilotConfiguration(), "fresh context starts with default configuration")
        check(await context1.restorePersistedList() == .none, "restore without archive is a no-op")
        check(context1.restoreAttempted, "restore gate latches after first attempt")

        let fixture7 = try makeSetDirectory(name: "t7", ids: [101, 102], contents: [101: regularJSON, 102: "{ broken"])
        state = CopilotListState(
            setPath: fixture7.path(percentEncoded: false), order: ["101#0"],
            overrides: ["101#0": .init(isOn: true, isRaid: true, navOverride: nil)])
        CopilotPersistence.saveListState(state)

        let context2 = CopilotContext()
        let outcome2 = await context2.restorePersistedList()
        check(outcome2 == .restored(active: 1, skipped: ["102.json（文件损坏）"]), "restore reports active count and skip reasons")
        check(context2.copilotList.map(\.memberID) == ["101#0"], "restored list carries surviving member")
        check(context2.copilotList[0].isRaid == true && context2.copilotList[0].isOn == true, "restored overrides applied")
        check(context2.copilotSet != nil, "restored set context exists")
        // URL(fileURLWithPath:) standardizes an existing directory with a
        // trailing slash, so compare slash-normalized path strings.
        check(
            normalizedPath(context2.copilotSet?.url) == normalizedPath(fixture7),
            "restored set context populated")
        check(await context2.restorePersistedList() == .none, "second restore attempt is gated off")

        CopilotPersistence.saveListState(CopilotListState(setPath: "/nonexistent/set", order: [], overrides: [:]))
        let context3 = CopilotContext()
        check(await context3.restorePersistedList() == .failed(.setUnreadable), "unavailable set directory restores as failure")

        clearStore()
        CopilotPersistence.saveListState(state)
        let context4 = CopilotContext()
        context4.copilotList = [row("777#0", isRaid: nil, isOn: true)]
        check(await context4.restorePersistedList() == .none, "restore does not clobber a live activation")
        check(context4.copilotList.map(\.memberID) == ["777#0"], "live rows preserved")

        clearStore()
        CopilotPersistence.saveListState(CopilotListState(setPath: nil, order: [], overrides: [:]))
        let context5 = CopilotContext()
        check(await context5.restorePersistedList() == .none, "cleared archive restores as no-op")

        // MARK: - E2. Restore adversarial regressions (评审 P13-1-R3 中危-1/中危-2/低-2/低-3/低-5)

        defer {
            MAAProvider.overrideMap = nil
            MAAProvider.mapDelayNanoseconds = 0
        }

        // 中危-2：降级恢复（映射瞬时失败）不得销毁被跳过成员的归档——61 正常恢复
        // 且用户勾选态套用；62 映射失败跳过，其旧存档 isOn=false + navOverride 以
        // 合并式保留（下次资源就绪恢复时按用户此前勾选回归，而非缺省 isOn=true）。
        do {
            clearStore()
            let sentinelJSON = #"{"stage_name":"SENTINEL-62","opers":[],"minimum_required":"v4.0"}"#
            let fixtureD = try makeSetDirectory(name: "t-degraded", ids: [61, 62], contents: [61: regularJSON, 62: sentinelJSON])
            let degradedArchive = CopilotListState(
                setPath: fixtureD.path(percentEncoded: false),
                order: ["61#0", "62#0"],
                overrides: [
                    "61#0": .init(isOn: false, isRaid: nil, navOverride: nil),
                    "62#0": .init(isOn: false, isRaid: nil, navOverride: "AC-5"),
                ])
            CopilotPersistence.saveListState(degradedArchive)
            MAAProvider.overrideMap = ["SENTINEL-62": nil]  // 62 的 stage_name 改写后恒 nil（模拟瞬时映射失败）
            let contextD = CopilotContext()
            let degradedOutcome = await contextD.restorePersistedList()
            check(degradedOutcome == .restored(active: 0, skipped: ["62.json（导航名映射失败）"]),
                  "degraded restore reports the mapped-failure skip reason")
            check(contextD.copilotList.map(\.memberID) == ["61#0"], "surviving member restored alone")
            check(contextD.copilotList[0].isOn == false, "surviving member keeps its archived off state")
            let merged = CopilotPersistence.loadListState()
            check(merged?.overrides["62#0"]?.isOn == false && merged?.overrides["62#0"]?.navOverride == "AC-5",
                  "skipped member's archived override preserved (not destroyed by degraded capture)")
            check(merged?.order.contains("62#0") == true, "skipped member's order key preserved for later restore")
            MAAProvider.overrideMap = nil
        }

        // 中危-1：恢复派生窗口内的手工激活不被覆盖、存档保留手工激活态
        //（延迟桩拉宽悬点窗口；活态保护复查必须在 await 之后）。
        do {
            clearStore()
            let fixtureC = try makeSetDirectory(name: "t-concurrent", ids: [201, 202], contents: [201: regularJSON, 202: regularJSON])
            CopilotPersistence.saveListState(CopilotListState(
                setPath: fixtureC.path(percentEncoded: false), order: ["201#0"], overrides: [:]))
            MAAProvider.mapDelayNanoseconds = 150_000_000
            let contextC = CopilotContext()
            let restoreTask = Task { await contextC.restorePersistedList() }
            try? await Task.sleep(nanoseconds: 80_000_000)  // 落入派生窗口（每成员 ~150ms × 2）
            contextC.copilotList = [row("999#0", isRaid: nil, isOn: true)]
            let concurrentOutcome = await restoreTask.value
            check(concurrentOutcome == .none, "restore abandons when manual activation landed in the derivation window")
            check(contextC.copilotList.map(\.memberID) == ["999#0"], "manual activation rows survive the restore window")
            check(CopilotPersistence.loadListState()?.order == ["999#0"],
                  "manual activation archive not clobbered by restore persistence")
        }

        // 低-3：难度值越界成员记因跳过（不再静默丢弃）。
        do {
            clearStore()
            let unsupportedJSON = #"{"stage_name":"1-7","opers":[],"minimum_required":"v4.0","difficulty":4}"#
            let fixtureU = try makeSetDirectory(name: "t-difficulty", ids: [71, 72], contents: [71: regularJSON, 72: unsupportedJSON])
            CopilotPersistence.saveListState(CopilotListState(
                setPath: fixtureU.path(percentEncoded: false), order: [], overrides: [:]))
            let contextU = CopilotContext()
            let unsupportedOutcome = await contextU.restorePersistedList()
            check(unsupportedOutcome == .restored(active: 1, skipped: ["72.json（难度值不支持）"]),
                  "unsupported difficulty member skips with a recorded reason")
            check(contextU.copilotList.map(\.memberID) == ["71#0"], "supported member unaffected")
        }

        // 低-2：损坏列表存档走 .failed(.archiveCorrupt)（与"无存档"区分记因）。
        do {
            clearStore()
            CopilotPersistence.store.set(Data("not json".utf8), forKey: "CopilotListState")
            let contextE = CopilotContext()
            check(await contextE.restorePersistedList() == .failed(.archiveCorrupt),
                  "corrupt archive reports archiveCorrupt (not silent none)")
        }

        // MARK: - F. didSet persistence wiring

        clearStore()
        let context6 = CopilotContext()
        context6.copilotList = [row("101#0", isRaid: nil, isOn: true), row("102#0", isRaid: nil, isOn: true)]
        check(CopilotPersistence.loadListState()?.setPath == nil, "manual rows persist without a set path")
        check(CopilotPersistence.loadListState()?.order == ["101#0", "102#0"], "manual row order persists")

        // Both members must be the SAME kind: mixed-kind listings are rejected
        // wholesale, which would leave the list empty and break the wiring
        // checks below.
        let fixture8 = try makeSetDirectory(name: "t8", ids: [101, 102], contents: [101: regularJSON, 102: regularJSON])
        let context7 = CopilotContext()
        _ = await context7.updateSet(at: fixture8)
        let savedState = CopilotPersistence.loadListState()
        check(savedState?.setPath == fixture8.path(percentEncoded: false), "activation persists the set path (path string)")
        check(savedState?.order == ["101#0", "102#0"], "activation persists derived row order")
        check(savedState?.overrides["101#0"]?.isOn == true, "activation persists row checked state")

        let secondID = context7.copilotList[1].id
        check(context7.canMoveRow(of: secondID, by: 1) == false, "move down past the end is rejected")
        check(context7.canMoveRow(of: secondID, by: -1) == true, "move up within bounds allowed")
        context7.moveRow(of: secondID, by: -1)
        check(context7.copilotList.map(\.memberID) == ["102#0", "101#0"], "move up swaps rows")
        check(CopilotPersistence.loadListState()?.order == ["102#0", "101#0"], "reorder persists")

        context7.copilotList.removeAll()
        check(CopilotPersistence.loadListState()?.setPath == nil, "clearing the list clears the archived set path")

        clearStore()
        let context8 = CopilotContext()
        context8.config.loop_times = 7
        check(CopilotPersistence.loadConfiguration()?.loop_times == 7, "configuration edits persist through didSet")
        let context9 = CopilotContext()
        check(context9.config.loop_times == 7, "configuration restores into a fresh context")

        // MARK: - G. C08 gate and config carry-through (P13-[c] regression)

        clearStore()
        let contextG1 = CopilotContext()
        contextG1.config.user_additional = [.init(name: "Amiya", skill: 3)]
        contextG1.config.loop_times = 5
        check(
            CopilotCompiler.Input(context: contextG1).config.user_additional.isEmpty,
            "gate off drops user_additional from the compiler input")
        check(
            CopilotCompiler.Input(context: contextG1).config.loop_times == 5,
            "context configuration carries into the compiler input")
        contextG1.enableUserAdditional = true
        check(
            CopilotCompiler.Input(context: contextG1).config.user_additional == [.init(name: "Amiya", skill: 3)],
            "gate on keeps user_additional")

        // MARK: - H. PRTS code parsing (C02)

        func parseCode(_ string: String) -> PRTSCode? {
            string.prtsCode
        }
        check(parseCode("12345") == .copilot(12345), "bare digits parse as copilot id")
        check(parseCode("prts://12345") == .copilot(12345), "prts:// parses as copilot id")
        check(parseCode("prts://s12345") == .set(12345), "prts://s parses as set id")
        check(parseCode("s12345") == .set(12345), "bare s-prefix parses as set id")
        check(parseCode("maa://12345") == .copilot(12345), "maa:// parses as copilot id (WPF parity)")
        check(parseCode("maa://abc") == nil, "maa:// with non-digits rejects")
        check(parseCode("prts://") == nil, "empty prts code rejects")
        check(parseCode("prts://s") == nil, "set prefix without digits rejects")
        check(parseCode("  prts://12345  ") == .copilot(12345), "surrounding whitespace trims")
        check(parseCode("99999999999999999999999") == nil, "overflowing id rejects instead of crashing")
        check(parseCode("not-a-code") == nil, "non-numeric input rejects")

        // MARK: - I. C11 operbox assist export and params passthrough

        let exportDir = FileManager.default.temporaryDirectory
            .appending(path: "operbox-assist-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: exportDir) }
        OperBoxAssistExport.overrideDirectory = exportDir
        defer { OperBoxAssistExport.overrideDirectory = nil }

        let skilled = OperBoxHistoryPayload.OwnedOperator(
            id: "char_002_amiya", own: true, name: "阿米娅", rarity: 5, elite: 2, level: 80,
            potential: 5, mainSkillLevel: 7, skills: [.init(id: "skchr_amiya_1", level: 3)])
        let unskilled = OperBoxHistoryPayload.OwnedOperator(
            id: "char_001_boom", own: true, name: "克洛丝", rarity: 3, elite: 1, level: 40, potential: 1)
        let assistPayload = OperBoxHistoryPayload(
            done: true,
            allOperators: [.init(id: "char_002_amiya", own: true, name: "阿米娅", rarity: 5)],
            ownedOperators: [skilled, unskilled])
        check(OperBoxAssistExport.isAssistUsable(assistPayload), "payload with any skills is assist-usable")
        check(
            !OperBoxAssistExport.isAssistUsable(
                OperBoxHistoryPayload(
                    done: true, allOperators: assistPayload.allOperators,
                    ownedOperators: [unskilled])),
            "payload without any skills is not assist-usable")

        let exportedURL = try OperBoxAssistExport.write(
            assistPayload, source: "yituliu", syncTime: Date(timeIntervalSince1970: 1_700_000_000))
        let exported = try JSONSerialization.jsonObject(with: Data(contentsOf: exportedURL)) as! [String: Any]
        check(exported["done"] as? Bool == true && exported["source"] as? String == "yituliu", "export carries done/source")
        check(exported["syncTime"] != nil, "export carries ISO8601 syncTime")
        let opers = exported["own_opers"] as! [[String: Any]]
        check(opers.count == 2, "export writes every owned operator")
        check(opers[0]["skills"] != nil && opers[0]["mainSkillLevel"] != nil, "skilled operator carries skills/mainSkillLevel")
        check(opers[1]["skills"] == nil && opers[1]["mainSkillLevel"] == nil, "nil fields are omitted instead of null")

        // Single-file compilation checks the file on disk; provide a real one.
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Data(regularJSON.utf8).write(to: base.appending(path: "101.json"))

        var assistConfig = CopilotConfiguration()
        assistConfig.operbox_data_path = "/tmp/maa-assist/OperBoxData.json"
        var assistOutputs: [CopilotCompiler.Output] = []
        if case .success(let outputs) = CopilotCompiler.compile(
            .init(selection: .single(url: base.appending(path: "101.json"), kind: .regular), config: assistConfig))
        {
            assistOutputs = outputs
        }
        check(!assistOutputs.isEmpty, "assist compile succeeds")
        check(
            assistOutputs.first?.config.operbox_data_path == "/tmp/maa-assist/OperBoxData.json",
            "operbox path passes through compilation")

        var plainOutputs: [CopilotCompiler.Output] = []
        if case .success(let outputs) = CopilotCompiler.compile(
            .init(selection: .single(url: base.appending(path: "101.json"), kind: .regular)))
        {
            plainOutputs = outputs
        }
        check(
            plainOutputs.first?.config.operbox_data_path == nil,
            "operbox path stays absent when not configured")

        // MARK: - J. C03-C07/C06/C11 dispatch condition matrix (P14.2：P14-1-R3 中1/中2)

        // P14-[d] assist gate truth table（WPF EffectiveOperBoxAssist = EnableOperBoxAssist && Form，
        // CopilotViewModel.cs:570-573——formation 关=不写盘下发/不预检不阻断）。
        check(
            CopilotDispatchPolicy.assistEffective(enableOperBoxAssist: false, formation: true) == false,
            "assist off → ineffective even with formation on")
        check(
            CopilotDispatchPolicy.assistEffective(enableOperBoxAssist: true, formation: false) == false,
            "formation off → ineffective (P14-[d] core case：@Defaults 开关存续不再生效)")
        check(
            CopilotDispatchPolicy.assistEffective(enableOperBoxAssist: true, formation: true) == true,
            "assist + formation on → effective")
        check(
            CopilotDispatchPolicy.assistEffective(enableOperBoxAssist: false, formation: false) == false,
            "both off → ineffective")

        // P14-[e] sanity potion truth table（WPF 列表 :2291 逐项直传 / 单文件 :2347 硬编码 false，
        // CopilotView.xaml:503 复选框仅列表模式可见——Core CopilotTask.cpp:71/200 单文件真实消费）。
        check(
            CopilotDispatchPolicy.sanityPotionValue(listMode: true, configured: true) == true,
            "list mode keeps user value on")
        check(
            CopilotDispatchPolicy.sanityPotionValue(listMode: true, configured: false) == false,
            "list mode keeps user value off")
        check(
            CopilotDispatchPolicy.sanityPotionValue(listMode: false, configured: true) == false,
            "single-file mode forces false regardless of configured (P14-[e] core case)")
        check(
            CopilotDispatchPolicy.sanityPotionValue(listMode: false, configured: false) == false,
            "single-file mode off stays off")

        // 混合列表：formation 关的成员不携带路径（分派循环逐项过滤面同构）。
        var mixedOn = CopilotConfiguration()
        mixedOn.formation = true
        var mixedOff = CopilotConfiguration()
        mixedOff.formation = false
        var mixed = [mixedOn, mixedOff]
        let enableAssist = true
        for index in mixed.indices where !CopilotDispatchPolicy.assistEffective(
            enableOperBoxAssist: enableAssist, formation: mixed[index].formation)
        {
            mixed[index].operbox_data_path = nil
        }
        for index in mixed.indices where CopilotDispatchPolicy.assistEffective(
            enableOperBoxAssist: enableAssist, formation: mixed[index].formation)
        {
            mixed[index].operbox_data_path = "/tmp/maa-assist/OperBoxData.json"
        }
        check(
            mixed[0].operbox_data_path == "/tmp/maa-assist/OperBoxData.json"
                && mixed[1].operbox_data_path == nil,
            "mixed list dispatches path only to formation-on members")

        if failures.isEmpty {
            print("ALL \(checkIndex) CHECKS PASSED")
        } else {
            print("\(failures.count)/\(checkIndex) CHECKS FAILED")
            FileHandle.standardError.write(Data(failures.joined(separator: "\n").utf8))
            exit(1)
        }
    }
}
