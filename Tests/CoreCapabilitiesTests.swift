import Foundation

// Compile the production capability derivation without launching the app or
// linking MaaCore. MAAClientChannel lives in StartupConfiguration.swift in the
// app target; P06.1 起 FightConfiguration 引用真实目录/活动层，桩 enum 失效——
// MAAClientChannel 由脚本提取的真实定义提供（含 isGlobal 语义），任务壳仍为桩。

typealias MAATaskConfiguration = Codable & Hashable & Sendable

enum MAATaskType: String {
    case Fight
    var description: String { rawValue }
}

enum MAATask {
    case fight(FightConfiguration)
}

@main
struct CoreCapabilitiesTests {
    static func main() throws {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("maa-core-capabilities-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        var failures = [String]()
        var caseCount = 0

        func check(
            _ name: String,
            coreVersion: String?, resourceRoot: URL?, channel: MAAClientChannel,
            tasksResourceRoot: URL? = nil,
            expect: (seriesUpperBound: Int, secretFront: Bool, recycle: Bool, versionMet: Bool)
        ) {
            caseCount += 1
            let caps = CoreCapabilities.derive(
                coreVersion: coreVersion, resourceRoot: resourceRoot, channel: channel,
                tasksResourceRoot: tasksResourceRoot)
            let actual = (
                seriesUpperBound: caps.seriesUpperBound,
                secretFront: caps.secretFrontAvailable,
                recycle: caps.recycleProductAvailable,
                versionMet: caps.minimumCoreVersionMet
            )
            if actual != expect {
                failures.append(
                    "\(name): got \(actual), want \(expect) [coreVersion=\(coreVersion ?? "nil"), channel=\(channel)]")
            }
        }

        func makeRoot(_ name: String) throws -> URL {
            let root = workspace.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return root
        }

        /// Writes a JSON object at `path` (relative, "/"-separated) creating parents.
        func writeJSON(_ root: URL, path: String, _ object: [String: Any]) throws {
            let target = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: object).write(to: target)
        }

        func writeRaw(_ root: URL, path: String, _ data: Data) throws {
            let target = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target)
        }

        // MARK: Fixture trees

        let secretFrontKeys: [String: Any] = [
            "MiniGame@SecretFront@Begin": ["algorithm": "justreturn"],
            "MiniGame@SecretFront@Run": ["algorithm": "justreturn"],
            "MiniGame@SecretFront@SelectTeam": ["algorithm": "justreturn"],
            "MiniGame@SecretFront@Actions": ["algorithm": "justreturn"],
            "MiniGame@SecretFront@End": ["algorithm": "justreturn"],
        ]
        let secretFrontTemplates = [
            "SelectTeam", "TeamManagement", "TeamIntelligence", "TeamMedicine",
        ]

        // CN new resources: no OldMethodFlag, SecretFront complete, RecycleProduct node present.
        let cnNew = try makeRoot("cn-new")
        try writeJSON(cnNew, path: "tasks.json", secretFrontKeys.merging([
            "InfrastRewardRecycleProduct": ["algorithm": "matchTemplate"],
        ]) { _, new in new })
        for template in secretFrontTemplates {
            try writeRaw(cnNew, path: "template/MiniGame/SecretFront/MiniGame@SecretFront@\(template).png", Data([0x89, 0x50]))
        }

        // Global legacy resources: OldMethodFlag set, no SecretFront, no RecycleProduct.
        let globalOld = try makeRoot("global-old")
        try writeJSON(globalOld, path: "tasks.json", ["FightSeries-OldMethodFlag": ["roi": [0, 0, 1, 1]]])

        // Pre-B15 CN resources: SecretFront complete but no RecycleProduct node.
        let cnPreB15 = try makeRoot("cn-pre-b15")
        try writeJSON(cnPreB15, path: "tasks.json", secretFrontKeys)
        for template in secretFrontTemplates {
            try writeRaw(cnPreB15, path: "template/MiniGame/SecretFront/MiniGame@SecretFront@\(template).png", Data([0x89, 0x50]))
        }

        // Nested layout: definitions only under tasks/tasks.json.
        let nested = try makeRoot("nested")
        try writeJSON(nested, path: "tasks/tasks.json", ["InfrastRewardRecycleProduct": [:]])

        // Corrupt tasks.json: unparseable bytes must not read as available.
        let corrupt = try makeRoot("corrupt")
        try writeRaw(corrupt, path: "tasks.json", Data("{not-json".utf8))

        // Array-typed tasks.json: wrong shape, same conservative outcome.
        let arrayShaped = try makeRoot("array-shaped")
        try writeRaw(arrayShaped, path: "tasks.json", Data("[1,2,3]".utf8))

        let emptyRoot = try makeRoot("empty")

        // Effective-root fixtures (R2-1): cache/user/bundle trees carrying only
        // a tasks marker file -- the resolver checks existence, not content.
        func makeBase(_ name: String, tasksPath: String) throws -> URL {
            let base = try makeRoot(name)
            try writeRaw(base, path: "resource/\(tasksPath)", Data("{}".utf8))
            return base
        }
        func makeGlobalBase(_ name: String) throws -> URL {
            let base = try makeRoot(name)
            try writeRaw(
                base, path: "resource/global/YoStarEN/resource/tasks/tasks.json",
                Data("{}".utf8))
            return base
        }
        let cacheCN = try makeBase("cache-cn", tasksPath: "tasks/tasks.json")
        let cacheEN = try makeGlobalBase("cache-en")
        let bundleCN = try makeBase("bundle-cn", tasksPath: "tasks.json")
        let bareBase = try makeRoot("bare-base")

        // MARK: Matrix

        // 1. CN new resources + readable Core version: everything on.
        check(
            "CN new resources with core version", coreVersion: "5.13.0", resourceRoot: cnNew,
            channel: .Official,
            expect: (seriesUpperBound: 10, secretFront: true, recycle: true, versionMet: true))

        // 2. Same tree, coreVersion nil: recycle and version gate close, rest intact.
        check(
            "CN new resources without core version", coreVersion: nil, resourceRoot: cnNew,
            channel: .Official,
            expect: (seriesUpperBound: 10, secretFront: true, recycle: false, versionMet: false))

        // 3. Bilibili is a non-global channel: same derivation as Official.
        check(
            "CN new resources on Bilibili", coreVersion: "5.13.0", resourceRoot: cnNew,
            channel: .Bilibili,
            expect: (seriesUpperBound: 10, secretFront: true, recycle: true, versionMet: true))

        // 4. Global legacy resources on a global channel: series 6, all boolean gates off.
        check(
            "global legacy resources on YoStarEN", coreVersion: "5.13.0", resourceRoot: globalOld,
            channel: .YoStarEN,
            expect: (seriesUpperBound: 6, secretFront: false, recycle: false, versionMet: true))

        // 5. Global channel + SecretFront-capable overlay stays unavailable:
        //    existing unavailableReason semantics treat global channels as unverified.
        check(
            "global channel with SecretFront-capable resources", coreVersion: "5.13.0",
            resourceRoot: cnNew, channel: .YoStarEN,
            expect: (seriesUpperBound: 10, secretFront: false, recycle: true, versionMet: true))

        // 6. Pre-B15 CN resources: SecretFront on, recycle node absent.
        check(
            "pre-B15 CN resources", coreVersion: "5.13.0", resourceRoot: cnPreB15,
            channel: .Official,
            expect: (seriesUpperBound: 10, secretFront: true, recycle: false, versionMet: true))

        // 7. Official channel over global legacy resources: series 6; SecretFront
        //    missing its definitions/templates; recycle node absent.
        check(
            "global legacy resources on Official", coreVersion: "5.13.0", resourceRoot: globalOld,
            channel: .Official,
            expect: (seriesUpperBound: 6, secretFront: false, recycle: false, versionMet: true))

        // 8. Nested tasks/tasks.json layout is probed too.
        check(
            "nested tasks.json with recycle node", coreVersion: "5.13.0", resourceRoot: nested,
            channel: .Official,
            expect: (seriesUpperBound: 10, secretFront: false, recycle: true, versionMet: true))

        // 9. Corrupt and wrong-shaped tasks.json fall back conservatively.
        check(
            "corrupt tasks.json", coreVersion: "5.13.0", resourceRoot: corrupt, channel: .Official,
            expect: (seriesUpperBound: 10, secretFront: false, recycle: false, versionMet: true))
        check(
            "array-shaped tasks.json", coreVersion: "5.13.0", resourceRoot: arrayShaped,
            channel: .Official,
            expect: (seriesUpperBound: 10, secretFront: false, recycle: false, versionMet: true))

        // 10. Empty root / nil root: boolean capabilities all false; series keeps
        //     the P01.1 default (10) per its missing-definition argument.
        check(
            "empty root", coreVersion: "5.13.0", resourceRoot: emptyRoot, channel: .Official,
            expect: (seriesUpperBound: 10, secretFront: false, recycle: false, versionMet: true))
        check(
            "nil root", coreVersion: "5.13.0", resourceRoot: nil, channel: .Official,
            expect: (seriesUpperBound: 10, secretFront: false, recycle: false, versionMet: true))
        check(
            "nil root without core version", coreVersion: nil, resourceRoot: nil,
            channel: .Official,
            expect: (seriesUpperBound: 10, secretFront: false, recycle: false, versionMet: false))

        // 11. Global channel without resources: unavailable regardless.
        check(
            "global channel, nil root", coreVersion: nil, resourceRoot: nil, channel: .YoStarJP,
            expect: (seriesUpperBound: 10, secretFront: false, recycle: false, versionMet: false))

        // 12. Blank coreVersion strings behave like nil after trimming.
        check(
            "blank core version", coreVersion: "  \n", resourceRoot: cnNew, channel: .Official,
            expect: (seriesUpperBound: 10, secretFront: true, recycle: false, versionMet: false))

        // 13. conservativeDefault equals the fully-conservative derivation.
        caseCount += 1
        if CoreCapabilities.conservativeDefault
            != CoreCapabilities.derive(coreVersion: nil, resourceRoot: nil, channel: .Official)
        {
            failures.append("conservativeDefault != derive(nil, nil, .Official)")
        }

        // MARK: Overlay-aware tasks root (R2-1)

        // 14. YoStarEN with a flag-less CN base root but the global overlay
        //     (OldMethodFlag, no RecycleProduct) resolved as tasks root: the
        //     overlay must win for series/recycle -- the pre-R2 shape reported 10.
        check(
            "global overlay tasks root wins for series", coreVersion: "5.13.0",
            resourceRoot: cnNew, channel: .YoStarEN, tasksResourceRoot: globalOld,
            expect: (seriesUpperBound: 6, secretFront: false, recycle: false, versionMet: true))

        // 15. Same inputs without an explicit tasks root fall back to the base
        //     root: series 10 and the CN recycle node visible again.
        check(
            "tasks root fallback to base root", coreVersion: "5.13.0",
            resourceRoot: cnNew, channel: .YoStarEN, tasksResourceRoot: nil,
            expect: (seriesUpperBound: 10, secretFront: false, recycle: true, versionMet: true))

        // 16. effectiveResourceRoot resolution order and overlay selection.
        caseCount += 1
        let resolved = [
            ("cache precedence (CN)", CoreCapabilities.effectiveResourceRoot(
                channel: .Official, cacheRoot: cacheCN, userRoot: bundleCN, bundleRoot: nil),
             cacheCN.appendingPathComponent("resource")),
            ("global overlay from cache", CoreCapabilities.effectiveResourceRoot(
                channel: .YoStarEN, cacheRoot: cacheEN, userRoot: nil, bundleRoot: bundleCN),
             cacheEN.appendingPathComponent("resource/global/YoStarEN/resource")),
            ("bundle fallback", CoreCapabilities.effectiveResourceRoot(
                channel: .Official, cacheRoot: bareBase, userRoot: nil, bundleRoot: bundleCN),
             bundleCN.appendingPathComponent("resource")),
            ("no tasks anywhere -> nil", CoreCapabilities.effectiveResourceRoot(
                channel: .Official, cacheRoot: bareBase, userRoot: nil, bundleRoot: nil),
             nil),
        ]
        for (name, actual, expected) in resolved where actual != expected {
            failures.append(
                "effectiveResourceRoot \(name): \(actual?.path ?? "nil") != \(expected?.path ?? "nil")")
        }

        for failure in failures { print("FAIL: \(failure)") }
        guard failures.isEmpty else { exit(1) }
        print(
            "PASS: \(caseCount) capability cases; resource matrix, channel matrix, coreVersion gating and overlay-aware root resolution"
        )
    }
}
