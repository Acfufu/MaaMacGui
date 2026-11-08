import Foundation

// Compile the production model without launching the app or linking MaaCore.
typealias MAATaskConfiguration = Codable & Hashable & Sendable

enum MAATaskType: String {
    case Fight
    var description: String { rawValue }
}

enum MAATask {
    case fight(FightConfiguration)
}

// P06.1 起 StageCatalog 进入 FightConfiguration 的编译面，真实
// StageActivityContext 由套件脚本供给（StageActivity.swift + 提取的活动模型），
// 原最小桩删除。

@main
struct FightConfigurationTests {
    static func main() throws {
        let cases: [(String, String)] = [
            ("AP-5", "AP-5"), ("ap-5", "AP-5"), ("Ap-5", "AP-5"), ("aP-5", "AP-5"),
            (" \tAp-5\r\n", "AP-5"), ("yw-8", "YW-8"), ("Yw-8", "YW-8"),
            ("pr-a-1", "PR-A-1"), ("Pr-a-1", "PR-A-1"), ("pR-A-1", "PR-A-1"),
            ("jt8-2", "JT8-2"), ("Jt8-2", "JT8-2"), ("s3-1", "S3-1"), ("1-7", "1-7"),
            ("Annihilation", "Annihilation"), ("annihilation", "Annihilation"),
            (" ANNIHILATION ", "Annihilation"), ("aNnIhIlAtIoN", "Annihilation"),
            ("AveMujica-8", "AveMujica-8"), (" AveMujica-8 ", "AveMujica-8"),
            ("GTToGT-5", "GTToGT-5"), ("CustomStage-1", "CustomStage-1"),
            ("avemujica-8", "avemujica-8"), ("customstage-1", "customstage-1"),
            ("H10-1-Hard", "H10-1-Hard"), ("15-1-Normal", "15-1-Normal"),
            ("h10-1-hard", "h10-1-hard"),  // The core handles main-story difficulty suffixes.
            ("", ""), (" \n\t", ""), ("未知关卡", "未知关卡"), ("ＡＰ-5", "ＡＰ-5"),
            ("AP -5", "AP -5"),
            ("OF-F3", "OF-F3"), ("of-f3", "OF-F3"), ("Of-F3", "OF-F3"),
        ]
        var failures = [String]()
        for (input, expected) in cases {
            let normalized = FightConfiguration.normalizedStage(input)
            if normalized != expected {
                failures.append(
                    "normalize \(input.debugDescription): \(normalized.debugDescription) != \(expected.debugDescription)"
                )
            }
            if FightConfiguration.normalizedStage(normalized) != normalized {
                failures.append("not idempotent: \(input.debugDescription)")
            }

            let fixture: [String: Any] = [
                "stage": input, "medicine": 3, "medicine_expire_days": 2, "stone": 1,
                "times": 4, "series": 6, "drops": ["30012": 7], "report_to_penguin": true,
                "penguin_id": "test", "report_to_yituliu": true, "yituliu_id": "test",
                "server": "CN", "client_type": "Official", "DrGrandet": true,
            ]
            let config = try JSONDecoder().decode(
                FightConfiguration.self, from: JSONSerialization.data(withJSONObject: fixture))
            let encoded = try JSONEncoder().encode(config.params)
            let payload = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            var expectedPayload = fixture
            expectedPayload["stage"] = expected
            if !NSDictionary(dictionary: payload).isEqual(to: expectedPayload) {
                failures.append("unexpected payload: \(input.debugDescription)")
            }
            if config.stage != input {
                failures.append("params mutated the stored config: \(input.debugDescription)")
            }
            let persisted = try PropertyListEncoder().encode(config.params)
            let restored = try PropertyListDecoder().decode(FightConfiguration.self, from: persisted)
            if restored.stage != expected {
                failures.append("persistence round trip: \(input.debugDescription)")
            }
        }
        // F11 倍率语义(Core m_series 契约):-1=保留游戏内当前倍率;0=AUTO 按理智自动;
        // 1...10=指定档位。nil 为 GUI 存储形态,编码省略;Core JSON 缺省 1
        // (FightTask.cpp params.get("series",1)),即切至单倍,≠显式 -1。
        let seriesBase: [String: Any] = [
            "stage": "1-7", "medicine_expire_days": 0, "server": "CN", "client_type": "Official",
        ]
        func seriesPayload(of stored: Int?) throws -> [String: Any] {
            var config = try JSONDecoder().decode(
                FightConfiguration.self, from: JSONSerialization.data(withJSONObject: seriesBase))
            config.series = stored
            return try JSONSerialization.jsonObject(with: JSONEncoder().encode(config.params)) as! [String: Any]
        }
        // 编码契约:每档一行断言。
        for stored in [-1, 0] + Array(1...10) {
            let payload = try seriesPayload(of: stored)
            if payload["series"] as? Int != stored {
                failures.append("series encode \(stored): got \(payload["series"] ?? "missing")")
            }
        }
        do {
            let payload = try seriesPayload(of: nil)
            if payload.keys.contains("series") {
                failures.append("series encode nil: expected key omitted, got \(payload["series"] ?? "")")
            }
        }

        // 旧配置迁移:旧 plist 无 series 键 → 解码为 nil,再编码仍省略(不暗改成 0/1/-1)。
        let legacyData = try PropertyListSerialization.data(
            fromPropertyList: seriesBase, format: .xml, options: 0)
        let legacy = try PropertyListDecoder().decode(FightConfiguration.self, from: legacyData)
        if legacy.series != nil {
            failures.append("legacy plist decode: series should stay nil, got \(legacy.series!)")
        }
        let persisted = try PropertyListEncoder().encode(legacy.params)
        let restored = try PropertyListDecoder().decode(FightConfiguration.self, from: persisted)
        if restored.series != nil {
            failures.append("legacy plist round trip: series should stay omitted, got \(restored.series!)")
        }

        // 倍率上限资源探测:旧资源(global 服)定义 FightSeries-OldMethodFlag → 上限 6;
        // 无 flag → 上限 10;根缺失按新 UI 处理。
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("maa-series-fixture-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        func makeSeriesFixture(_ name: String, tasks: [String: Any]) throws -> URL {
            let root = fixtureRoot.appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent("resource", isDirectory: true)
            let tasksDir = root.appendingPathComponent("tasks", isDirectory: true)
            try FileManager.default.createDirectory(at: tasksDir, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: tasks)
                .write(to: tasksDir.appendingPathComponent("tasks.json"))
            return root
        }
        let oldRoot = try makeSeriesFixture(
            "old", tasks: ["FightSeries-OldMethodFlag": ["algorithm": "JustReturn"]])
        let newRoot = try makeSeriesFixture("new", tasks: ["FightSeries-Icon": ["template": "x.png"]])
        if FightConfiguration.seriesUpperBound(resourceRoot: oldRoot) != 6 {
            failures.append("seriesUpperBound old resource: expected 6")
        }
        if FightConfiguration.seriesUpperBound(resourceRoot: newRoot) != 10 {
            failures.append("seriesUpperBound new resource: expected 10")
        }
        if FightConfiguration.seriesUpperBound(resourceRoot: nil) != 10 {
            failures.append("seriesUpperBound missing root: expected 10")
        }
        // 平铺 tasks.json 候选路径(部分旧资源未分目录)。
        let flatRoot = fixtureRoot.appendingPathComponent("flat", isDirectory: true)
        try FileManager.default.createDirectory(at: flatRoot, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["FightSeries-OldMethodFlag": ["algorithm": "JustReturn"]])
            .write(to: flatRoot.appendingPathComponent("tasks.json"))
        if FightConfiguration.seriesUpperBound(resourceRoot: flatRoot) != 6 {
            failures.append("seriesUpperBound flat tasks.json: expected 6")
        }

        // F16/F17 掉落上报编码契约（P06.3）：企鹅/一图流两组键恒编码（对齐企鹅
        // plain-encode 先例，Core 侧 params.get 缺省与 GUI 关闭态一致）；缺键解码
        // 补 false/""；显式值往返不变。Core 51dac87 消费 yituliu enable 开关但
        // yituliu_id 未消费（FightTask.cpp 误传 penguin_id、插件 m_yituliu_id 零
        // 读取）——GUI 仍下发 ID 以兼容后续 pin，匿名怪点随 UI caption 记录。
        do {
            let empty = try JSONDecoder().decode(FightConfiguration.self, from: Data("{}".utf8))
            if empty.report_to_penguin || !empty.penguin_id.isEmpty {
                failures.append("empty decode penguin: expected false/\"\"")
            }
            if empty.report_to_yituliu || !empty.yituliu_id.isEmpty {
                failures.append("empty decode yituliu: expected false/\"\"")
            }
            let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(empty.params))
                as! [String: Any]
            for (key, expected) in [
                ("report_to_penguin", false as Any), ("penguin_id", "" as Any),
                ("report_to_yituliu", false as Any), ("yituliu_id", "" as Any),
            ] {
                if payload[key] == nil {
                    failures.append("report encode \(key): expected always encoded")
                } else if !(payload[key]! as! NSObject).isEqual(expected) {
                    failures.append("report encode \(key): got \(payload[key]!), expected \(expected)")
                }
            }
        }
        do {
            let json = #"{"report_to_penguin": true, "penguin_id": "peng", "report_to_yituliu": true, "yituliu_id": "yit"}"#
            let config = try JSONDecoder().decode(FightConfiguration.self, from: Data(json.utf8))
            let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config.params))
                as! [String: Any]
            if payload["report_to_penguin"] as? Bool != true || payload["penguin_id"] as? String != "peng" {
                failures.append("report encode penguin: got \(payload["report_to_penguin"] ?? "")/\(payload["penguin_id"] ?? "")")
            }
            if payload["report_to_yituliu"] as? Bool != true || payload["yituliu_id"] as? String != "yit" {
                failures.append("report encode yituliu: got \(payload["report_to_yituliu"] ?? "")/\(payload["yituliu_id"] ?? "")")
            }
            let persisted = try PropertyListEncoder().encode(config.params)
            let restored = try PropertyListDecoder().decode(FightConfiguration.self, from: persisted)
            if restored.report_to_yituliu != true || restored.yituliu_id != "yit" {
                failures.append("report plist round trip yituliu: got \(restored.report_to_yituliu)/\(restored.yituliu_id)")
            }
            if restored.report_to_penguin != true || restored.penguin_id != "peng" {
                failures.append("report plist round trip penguin: got \(restored.report_to_penguin)/\(restored.penguin_id)")
            }
        }

        for failure in failures { print("FAIL: \(failure)") }
        guard failures.isEmpty else { exit(1) }
        print(
            "PASS: \(cases.count) stage cases; normalization, idempotence, payload fields, value semantics and plist round trips"
        )
        print(
            "PASS: series encode contract (nil omitted; -1/0/1...10 verbatim), legacy migration unchanged, resource upper bound 6 vs 10"
        )
        print(
            "PASS: F16/F17 report encode contract (penguin/yituliu always encoded; missing keys decode false/\\\"\\\"; explicit values round trip)"
        )

        // §5-19：weeklyDays 解码值域 0...6（HGCalendar.weekday 游戏日星期序号
        // 0=周日…6=周六，两侧写入面 Array(0...6) 同口径；S5.1 曾误用 1...7，S5.2
        // 订正——含空集语义与编码 round trip）。
        do {
            let junk = try JSONDecoder().decode(
                FightConfiguration.self,
                from: Data(#"{"weeklyDays":[0,3,9,-1]}"#.utf8)
            )
            if junk.weeklyDays != [0, 3] {
                failures.append("weeklyDays sanitize: got \(junk.weeklyDays.map(String.init) ?? "nil")")
            }
            let valid = try JSONDecoder().decode(
                FightConfiguration.self,
                from: Data(#"{"weeklyDays":[1,7]}"#.utf8)
            )
            if valid.weeklyDays != [1] {
                failures.append("weeklyDays valid passthrough: got \(valid.weeklyDays.map(String.init) ?? "nil")")
            }
            let absent = try JSONDecoder().decode(FightConfiguration.self, from: Data("{}".utf8))
            if absent.weeklyDays != nil {
                failures.append("weeklyDays absent decode: got \(absent.weeklyDays.map(String.init) ?? "non-nil")")
            }
            let empty = try JSONDecoder().decode(
                FightConfiguration.self,
                from: Data(#"{"weeklyDays":[]}"#.utf8)
            )
            if empty.weeklyDays != [] {
                failures.append("weeklyDays empty-set semantics: got \(empty.weeklyDays.map(String.init) ?? "non-empty-array")")
            }
            let roundTrip = try JSONDecoder().decode(
                FightConfiguration.self,
                from: JSONEncoder().encode(junk)
            )
            if roundTrip.weeklyDays != [0, 3] {
                failures.append("weeklyDays encode round trip: got \(roundTrip.weeklyDays.map(String.init) ?? "nil")")
            }
        } catch {
            failures.append("weeklyDays sanitize decode threw: \(error)")
        }

        // P17-[e]（快照 82 清单②裁定：随 WPF 对齐）：OTA 条目版本门——WPF
        // StageManager.cs:560-582 语义：需求不可解析→警示原文；当前可解析且
        // 低于需求→警示；当前不可解析→不警示（curVerParsed 门）；Tip 非硬门禁。
        do {
            let parseCases: [(String, (Int, Int, Int)?)] = [
                ("1.2", nil), ("1.2.3", (1, 2, 3)), ("v4.5.6", (4, 5, 6)),
                ("V0.1.0", nil), ("1", nil), ("1.2.3.4", nil), ("a.b", nil),
                ("1..3", nil), ("", nil), ("v", nil),
            ]
            for (input, expected) in parseCases {
                let got = StageActivityVersionGate.parseVersion(input).map { ($0.major, $0.minor, $0.patch) }
                let matches: Bool
                switch (got, expected) {
                case (nil, nil): matches = true
                case (let g?, let e?): matches = g == e
                default: matches = false
                }
                if !matches {
                    failures.append("P17-[e] parse \(input.debugDescription): got \(String(describing: got)), expected \(String(describing: expected))")
                }
            }
            let tipCases: [(String?, String, Bool, String)] = [
                ("1.2.4", "1.2.3", true, "current below required tips"),
                ("1.2.3", "1.2.4", false, "current above required no tip"),
                ("1.2.3", "1.2.3", false, "equal version no tip"),
                ("v1.2.0", "1.1.9", true, "lower-v prefix parses (patch required, S8-1-R3 中-2)"),
                ("not.a.version", "9.9.9", true, "unparseable required tips with raw text"),
                ("1.2", "1.2.5", true, "two-segment required unparseable -> always tips (WPF StageManager :468 no OptionalPatch)"),
                ("1.2.3", "garbage", false, "unparseable current no tip (curVerParsed gate)"),
                ("", "1.0.0", false, "empty required no tip"),
                (nil, "1.0.0", false, "nil required no tip"),
            ]
            for (required, current, expectTip, label) in tipCases {
                let tip = StageActivityVersionGate.lowVersionTip(minimumRequired: required, currentVersion: current)
                if (tip != nil) != expectTip {
                    failures.append("P17-[e] tip \(label): got \(String(describing: tip))")
                }
                if expectTip, let tip, !tip.contains(required ?? "") {
                    failures.append("P17-[e] tip text must carry raw required version: \(tip)")
                }
            }
        }

        for failure in failures { print("FAIL: \(failure)") }
        guard failures.isEmpty else { exit(1) }
        print("PASS: §5-19 weeklyDays decode sanitizes to 0...6 (junk dropped, valid kept, absent nil, empty set kept, round trip stable)")
    }
}
