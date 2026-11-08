import Foundation

// Exercise the pre-queue copilot parameter compiler (C16) against real fixture
// files. The production CopilotConfiguration.swift / MAACopilot.swift compiled
// alongside this file are verbatim; only external boundaries (Defaults,
// MAAProvider, MAATaskType, externalCopilotDirectory) are stubbed by the script.

@main
struct CopilotCompileTests {
    static func main() throws {
        let args = CommandLine.arguments.dropFirst()
        guard args.count == 3 else {
            FileHandle.standardError.write(
                Data("usage: copilot-compile-tests <regular.json> <sss.json> <paradox.json>".utf8))
            exit(2)
        }
        let regularURL = URL(fileURLWithPath: String(args[args.startIndex]))
        let sssURL = URL(fileURLWithPath: String(args[args.startIndex + 1]))
        let paradoxURL = URL(fileURLWithPath: String(args[args.startIndex + 2]))

        var failures = [String]()

        func expectSuccess(
            _ label: String, _ input: CopilotCompiler.Input, type: MAATaskType,
            filename: String?, list: [CopilotConfiguration.CopilotItem] = [],
            paradoxList: [CopilotConfiguration.ParadoxListItem]? = nil,
            taskCount: Int = 1, followingFilenames: [String] = [],
            base: CopilotConfiguration = CopilotConfiguration()
        ) {
            let result = CopilotCompiler.compile(input)
            guard case .success(let outputs) = result else {
                failures.append("\(label): expected success, got \(result)")
                return
            }
            if outputs.count != taskCount {
                failures.append("\(label): task count \(outputs.count) != \(taskCount)")
            }
            if outputs.dropFirst().map(\.config.filename) != followingFilenames {
                failures.append("\(label): following filenames \(outputs.dropFirst().map(\.config.filename)) != \(followingFilenames)")
            }
            guard let output = outputs.first else { return }
            if output.type != type {
                failures.append("\(label): type \(output.type) != \(type)")
            }
            if output.config.filename != filename {
                failures.append("\(label): filename \(String(describing: output.config.filename)) != \(String(describing: filename))")
            }
            if output.config.copilot_list != list {
                failures.append("\(label): copilot_list \(output.config.copilot_list) != \(list)")
            }
            if output.config.list != paradoxList {
                failures.append("\(label): list \(String(describing: output.config.list)) != \(String(describing: paradoxList))")
            }
            // Non-selection fields must pass through untouched.
            if output.config.loop_times != base.loop_times
                || output.config.formation != base.formation
                || output.config.support_unit_usage != base.support_unit_usage
            {
                failures.append("\(label): unrelated config fields were mutated")
            }
        }

        func expectFailure(
            _ label: String, _ input: CopilotCompiler.Input,
            _ error: CopilotCompileError, file: StaticString = #fileID, line: UInt = #line
        ) {
            let result = CopilotCompiler.compile(input)
            guard case .failure(let actual) = result else {
                failures.append("\(label): expected \(error), got \(result)")
                return
            }
            if actual != error {
                failures.append("\(label): \(actual) != \(error)")
            }
        }

        // 1. Single-file compilation: one fixture per kind, type mapping preserved.
        expectSuccess(
            "single regular", .init(selection: .single(url: regularURL, kind: .regular)),
            type: .Copilot, filename: regularURL.path(percentEncoded: false))
        expectSuccess(
            "single sss", .init(selection: .single(url: sssURL, kind: .sss)),
            type: .SSSCopilot, filename: sssURL.path(percentEncoded: false))
        expectSuccess(
            "single paradox", .init(selection: .single(url: paradoxURL, kind: .paradox)),
            type: .ParadoxCopilot, filename: paradoxURL.path(percentEncoded: false))

        // Base config (loop times, formation, support unit) survives compilation.
        var base = CopilotConfiguration()
        base.loop_times = 3
        base.formation = true
        base.support_unit_usage = .specific
        expectSuccess(
            "single keeps base config",
            .init(selection: .single(url: regularURL, kind: .regular), config: base),
            type: .Copilot, filename: regularURL.path(percentEncoded: false), base: base)

        // 2. List compilation: enabled entries map onto copilot_list in order.
        let tmp0 = FileManager.default.temporaryDirectory
            .appending(path: "maa-copilot-compile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp0, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp0) }
        let secondRegularURL = tmp0.appending(path: "regular-2.json")
        try FileManager.default.copyItem(at: regularURL, to: secondRegularURL)

        let raidItem = CopilotCompiler.Input.Item(url: regularURL, isOn: true, isRaid: true)
        let plainItem = CopilotCompiler.Input.Item(url: secondRegularURL, isOn: true, isRaid: nil)
        let offItem = CopilotCompiler.Input.Item(url: sssURL, isOn: false, isRaid: false)
        expectSuccess(
            "list mapping",
            .init(selection: .list(kind: .regular, items: [raidItem, plainItem, offItem])),
            type: .Copilot, filename: nil,
            list: [
                .init(filename: regularURL.path(percentEncoded: false), nav_name_override: nil, is_raid: true),
                .init(filename: secondRegularURL.path(percentEncoded: false), nav_name_override: nil, is_raid: false),
            ])

        // C10: per-row nav override passes through to copilot_list; an empty
        // override compiles as no override.
        expectSuccess(
            "nav override passthrough",
            .init(selection: .list(kind: .regular, items: [
                .init(url: regularURL, isOn: true, isRaid: false, navOverride: ""),
                .init(url: secondRegularURL, isOn: true, isRaid: false, navOverride: "OF-EX"),
            ])),
            type: .Copilot, filename: nil,
            list: [
                .init(filename: regularURL.path(percentEncoded: false), nav_name_override: nil, is_raid: false),
                .init(filename: secondRegularURL.path(percentEncoded: false), nav_name_override: "OF-EX", is_raid: false),
            ])

        // 3. Empty selection: no entry at all, or every entry toggled off.
        expectFailure(
            "empty item list", .init(selection: .list(kind: .regular, items: [])), .emptyList)
        expectFailure(
            "all toggled off", .init(selection: .list(kind: .sss, items: [offItem])), .emptyList)
        // An empty list must report emptyList even when the set carries no kind
        // (an empty list clears the set in CopilotContext).
        expectFailure(
            "empty beats missing kind", .init(selection: .list(kind: nil, items: [])), .emptyList)

        // 4. Missing kind on a non-empty list.
        expectFailure(
            "missing kind", .init(selection: .list(kind: nil, items: [raidItem])), .missingKind)

        // 5. Non-copilot content in single-file mode.
        expectFailure("unsupported content", .init(selection: .other), .unsupportedContent)

        // 6. Missing files: every missing filename is reported, not just the first.
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "maa-copilot-compile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let gone1 = tmp.appending(path: "gone-1.json")
        let gone2 = tmp.appending(path: "gone-2.json")

        expectFailure(
            "single missing file", .init(selection: .single(url: gone1, kind: .regular)),
            .missingFile([gone1.path(percentEncoded: false)]))
        expectFailure(
            "list missing files all listed",
            .init(selection: .list(kind: .regular, items: [
                .init(url: gone1, isOn: true, isRaid: false),
                .init(url: regularURL, isOn: true, isRaid: false),
                .init(url: gone2, isOn: true, isRaid: false),
            ])),
            .missingFile([gone1.path(percentEncoded: false), gone2.path(percentEncoded: false)]))

        // 7. Mixed kinds: an SSS file inside a regular set is rejected with the
        //    offending filenames; so is a file that no longer parses as a copilot.
        let corruptURL = tmp.appending(path: "corrupt.json")
        try Data("{ not a copilot".utf8).write(to: corruptURL)
        expectFailure(
            "sss file in regular set",
            .init(selection: .list(kind: .regular, items: [
                .init(url: regularURL, isOn: true, isRaid: false),
                .init(url: sssURL, isOn: true, isRaid: false),
            ])),
            .mixedKind(expected: .regular, offenders: [sssURL.path(percentEncoded: false)]))
        expectFailure(
            "undecodable file in regular set",
            .init(selection: .list(kind: .regular, items: [
                .init(url: regularURL, isOn: true, isRaid: false),
                .init(url: corruptURL, isOn: true, isRaid: false),
            ])),
            .mixedKind(expected: .regular, offenders: [corruptURL.path(percentEncoded: false)]))
        // A matching list of paradox files compiles to one ParadoxCopilot task
        // whose params carry `list: [{id, filename}]` (Core's ParadoxCopilotTask
        // reads neither `filename` nor `copilot_list` for sets).
        expectSuccess(
            "paradox list",
            .init(selection: .list(kind: .paradox, items: [
                .init(url: paradoxURL, isOn: true, isRaid: false),
            ])),
            type: .ParadoxCopilot, filename: nil,
            paradoxList: [.init(id: 1, filename: paradoxURL.path(percentEncoded: false))])

        // An SSS set compiles to one single-filename SSSCopilot task per file,
        // preserving the set order.
        let secondSSSURL = tmp0.appending(path: "sss-2.json")
        try FileManager.default.copyItem(at: sssURL, to: secondSSSURL)
        expectSuccess(
            "sss list expands to ordered single-file tasks",
            .init(selection: .list(kind: .sss, items: [
                .init(url: sssURL, isOn: true, isRaid: false),
                .init(url: secondSSSURL, isOn: true, isRaid: false),
            ])),
            type: .SSSCopilot, filename: sssURL.path(percentEncoded: false), taskCount: 2,
            followingFilenames: [secondSSSURL.path(percentEncoded: false)])
        // The same file's normal/raid rows collapse into one task.
        expectSuccess(
            "sss raid rows deduplicate",
            .init(selection: .list(kind: .sss, items: [
                .init(url: sssURL, isOn: true, isRaid: false),
                .init(url: sssURL, isOn: true, isRaid: true),
            ])),
            type: .SSSCopilot, filename: sssURL.path(percentEncoded: false), taskCount: 1)

        // 8. Every failure renders a non-empty user-facing log message.
        let samples: [CopilotCompileError] = [
            .emptyList, .missingKind, .unsupportedContent,
            .missingFile([gone1.path(percentEncoded: false)]),
            .mixedKind(expected: .sss, offenders: [sssURL.path(percentEncoded: false)]),
        ]
        for sample in samples where sample.logMessage.isEmpty {
            failures.append("empty log message for \(sample)")
        }

        // 9. Migration guard: the persisted configuration format still decodes.
        let stored: [String: Any] = [
            "enable": true, "filename": "/x/a.json",
            "copilot_list": [["filename": "/x/b.json", "nav_name_override": "n", "is_raid": true]],
            "loop_times": 4, "use_sanity_potion": true, "formation": true, "formation_index": 2,
            "user_additional": [["name": "阿米娅", "skill": 3]],
            "add_trust": true, "ignore_requirements": true,
            "support_unit_usage": 2, "support_unit_name": "棘刺",
        ]
        let decoded = try JSONDecoder().decode(
            CopilotConfiguration.self, from: JSONSerialization.data(withJSONObject: stored))
        let encoded = try JSONEncoder().encode(decoded)
        let restored = try JSONDecoder().decode(CopilotConfiguration.self, from: encoded)
        if decoded != restored
            || decoded.copilot_list.first?.nav_name_override != "n"
            || decoded.support_unit_usage != .specific
            || decoded.user_additional.first?.skill != 3
        {
            failures.append("CopilotConfiguration round trip changed persisted fields")
        }

        // 10. Wire-format contract: a paradox payload encodes `list` entries as
        //     {id, filename} (Core's ParadoxCopilotTask shape); a regular
        //     payload carries no `list` key at all (nil optionals are omitted).
        var paradoxConfig = CopilotConfiguration()
        paradoxConfig.list = [.init(id: 1, filename: "/x/p.json")]
        let paradoxJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(paradoxConfig)) as! [String: Any]
        let paradoxEntries = paradoxJSON["list"] as? [[String: Any]]
        if paradoxEntries?.first?["id"] as? Int != 1
            || paradoxEntries?.first?["filename"] as? String != "/x/p.json" {
            failures.append("paradox list payload shape mismatch")
        }
        let regularJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CopilotConfiguration())) as! [String: Any]
        if regularJSON["list"] != nil {
            failures.append("regular payload must not carry a list key")
        }

        for failure in failures { print("FAIL: \(failure)") }
        guard failures.isEmpty else { exit(1) }
        print("PASS: 3 single-file kinds, list mapping, paradox list payload, SSS ordered single-file tasks, empty/missing-kind/missing-file/mixed-kind rejections, log messages, config round trip")
    }
}
