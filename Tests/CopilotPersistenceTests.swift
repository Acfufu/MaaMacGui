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

        if failures.isEmpty {
            print("ALL \(checkIndex) CHECKS PASSED")
        } else {
            print("\(failures.count)/\(checkIndex) CHECKS FAILED")
            FileHandle.standardError.write(Data(failures.joined(separator: "\n").utf8))
            exit(1)
        }
    }
}
