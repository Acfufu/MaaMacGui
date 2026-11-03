//
//  FightConfiguration.swift
//  MAA
//
//  Created by hguandl on 16/4/2023.
//

import Foundation

struct FightConfiguration: MAATaskConfiguration {
    var type: MAATaskType { .Fight }

    var stage: String
    var medicine: Int?
    /// Q05 药仅一次：完整成功的运行结束后 medicine 置 nil（旧数据缺键解码 false）。
    var medicineOnce: Bool = false
    var medicine_expire_days: Int
    var useActivityMedicine: Bool = false
    var stone: Int?
    /// Q05 源石仅一次：完整成功的运行结束后 stone 置 nil（旧数据缺键解码 false）。
    var stoneOnce: Bool = false
    var times: Int?
    // 作战倍率(Core m_series 契约):-1=保留游戏内当前;0=AUTO 按理智自动;1...10=指定。
    // nil 为 GUI 存储形态,编码省略;Core JSON 缺省为 1(params.get("series",1)),即切至单倍,≠-1。
    var series: Int?
    var drops: [String: Int]?

    var inventoryTarget: InventoryTarget? = nil

    var report_to_penguin: Bool
    var penguin_id: String
    var server: String
    var client_type: String
    var DrGrandet: Bool

    var title: String {
        type.description
    }

    var subtitle: String {
        if stage == "" {
            return String(localized: "当前/上次")
        } else {
            return stage
        }
    }

    var summary: String {
        var parts = [String]()

        if let medicine {
            parts.append(String(localized: "理智药") + "\(medicine)")
        }

        if let stone {
            parts.append(String(localized: "源石") + "\(stone)")
        }

        if let times {
            parts.append("\(times)" + String(localized: "次"))
        }

        return parts.joined(separator: ";")
    }

    var projectedTask: MAATask {
        .fight(self)
    }

    struct Params: Encodable {
        fileprivate let configuration: FightConfiguration
        func encode(to encoder: any Encoder) throws {
            // A target must be prepared against a live snapshot before it reaches Core.
            guard configuration.inventoryTarget == nil else { throw InventoryTargetError.recognitionRequired }
            var container = encoder.container(keyedBy: CoreCodingKeys.self)
            let c = configuration
            try container.encode(c.stage, forKey: .stage)
            try container.encodeIfPresent(c.medicine, forKey: .medicine)
            try container.encode(c.medicine_expire_days, forKey: .medicine_expire_days)
            try container.encodeIfPresent(c.stone, forKey: .stone)
            try container.encodeIfPresent(c.times, forKey: .times)
            // series=-1 必须显式下发(保留当前);nil 省略时 Core 缺省 1(切至单倍),行为≠-1
            try container.encodeIfPresent(c.series, forKey: .series)
            try container.encodeIfPresent(c.drops, forKey: .drops)
            try container.encode(c.report_to_penguin, forKey: .report_to_penguin)
            try container.encode(c.penguin_id, forKey: .penguin_id)
            try container.encode(c.server, forKey: .server)
            try container.encode(c.client_type, forKey: .client_type)
            try container.encode(c.DrGrandet, forKey: .DrGrandet)
        }
        private enum CoreCodingKeys: String, CodingKey {
            case stage, medicine, medicine_expire_days, stone, times, series, drops
            case report_to_penguin, penguin_id, server, client_type, DrGrandet
        }

        var medicine_expire_days: Int { configuration.medicine_expire_days }
    }

    // Normalize short stage codes (AP-5, PR-A-1, JT8-2, OF-F3) regardless of input case.
    // Preserve special task names such as AveMujica-8 and difficulty suffixes;
    // the core already handles the latter case-insensitively.
    static func normalizedStage(_ stage: String) -> String {
        let trimmed = stage.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased() == "annihilation" {
            return "Annihilation"
        }
        if trimmed.range(of: "^[A-Za-z0-9]{1,3}(?:-[A-Za-z])?-[A-Za-z]?[0-9]+$", options: .regularExpression) != nil {
            return trimmed.uppercased()
        }
        return trimmed
    }

    // 倍率上限资源探测:旧资源(global 服)定义 FightSeries-OldMethodFlag → 旧倍率 UI,
    // 上限 6;CN 新资源无该 flag → 新 UI,上限 10。缺 tasks 定义或根不可用时按新 UI 处理。
    static func seriesUpperBound(resourceRoot: URL?) -> Int {
        guard let resourceRoot else { return 10 }
        for path in ["tasks.json", "tasks/tasks.json"] {
            guard let data = try? Data(contentsOf: resourceRoot.appendingPathComponent(path)),
                let tasks = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            if tasks["FightSeries-OldMethodFlag"] != nil { return 6 }
        }
        return 10
    }

    var params: Params {
        var config = self
        config.stage = Self.normalizedStage(config.stage)
        return Params(configuration: config)
    }

    func params(at date: Date, stageActivity: StageActivityContext) -> Params {
        var config = self
        config.stage = Self.normalizedStage(config.stage)
        if case .extended(let days) = stageActivity.medicineWindow(at: date, enabled: useActivityMedicine) {
            config.medicine_expire_days = max(medicine_expire_days, days)
        }
        return Params(configuration: config)
    }

    func preparingInventoryTarget(_ plan: InventoryTargetPlan) -> Self {
        var prepared = self
        if let target = inventoryTarget {
            prepared.drops = [target.itemID: plan.requiredDrops]
            prepared.inventoryTarget = nil
        }
        return prepared
    }

    // 掉落物品列表
    @MainActor static var dropItems: [(id: String, item: DropItem)] = []
    @MainActor static var inventoryDropItems: [(id: String, item: DropItem)] {
        dropItems.filter { InventoryTargetPlanner.supportsInventory(classification: $0.item.classifyType) }
    }
    @MainActor static var id2index: [String: Int] = [:]  // (id -> idx of dropItems)
    static let _excludedValues = Set([
        3213, 3223, 3233, 3243,  // 双芯片
        3253, 3263, 3273, 3283,  // 双芯片
        7001, 7002, 7003, 7004,  // 许可
        6001,  // 演习卷
        4004, 4005,  // 凭证
        3141, 4002,  // 源石
        32001,  // 芯片助剂
        30115,  // 聚合剂
        30125,  // 双极纳米片
        30135,  // D32钢
        30145,  // 晶体电子单元
        30155,  // 烧结核凝晶
    ])

    @MainActor static func initDropItems(_ language: String) throws {
        if !dropItems.isEmpty { return }
        let local: String? =
            switch language {
            case "zh-tw": "txwy"
            case "en-us": "YoStarEN"
            case "ja-jp": "YoStarJP"
            case "ko-kr": "YoStarKR"
            default: nil
            }
        let url_base = Bundle.main.resourceURL!
            .appendingPathComponent("resource")
        let url_mid =
            if let local {
                url_base.appendingPathComponent("global")
                    .appendingPathComponent(local)
                    .appendingPathComponent("resource")
            } else {
                url_base
            }
        let url = url_mid.appendingPathComponent("item_index.json")
        let data = try Data(contentsOf: url)
        let json = try JSONDecoder().decode([String: DropItem].self, from: data)
        for item in json {
            guard let k = Int(item.key) else { continue }
            guard !_excludedValues.contains(k) else { continue }
            dropItems.append((id: item.key, item: item.value))
        }
        dropItems.sort { $0.1.name.localizedCompare($1.1.name) == .orderedAscending }
        for (idx, item) in dropItems.enumerated() {
            id2index[item.0] = idx
        }
    }
}

struct DropItem: Codable, Equatable {
    let classifyType: String?
    let description: String?
    let icon: String
    let name: String
    let sortId: Int
    let usage: String?
}

private enum LegacyCodingKeys: String, CodingKey {
    case expiring_medicine
}

extension FightConfiguration {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.stage = try container.decodeIfPresent(String.self, forKey: .stage) ?? ""
        self.medicine = try container.decodeIfPresent(Int.self, forKey: .medicine)
        self.medicineOnce = try container.decodeIfPresent(Bool.self, forKey: .medicineOnce) ?? false
        if let days = try container.decodeIfPresent(Int.self, forKey: .medicine_expire_days) {
            medicine_expire_days = days
        } else {
            let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
            let medicine = try legacyContainer.decodeIfPresent(Int.self, forKey: .expiring_medicine)
            medicine_expire_days = (medicine ?? 0) > 0 ? 2 : 0
        }
        self.useActivityMedicine = try container.decodeIfPresent(Bool.self, forKey: .useActivityMedicine) ?? false
        self.stone = try container.decodeIfPresent(Int.self, forKey: .stone)
        self.stoneOnce = try container.decodeIfPresent(Bool.self, forKey: .stoneOnce) ?? false
        self.times = try container.decodeIfPresent(Int.self, forKey: .times)
        self.series = try container.decodeIfPresent(Int.self, forKey: .series)
        self.drops = try container.decodeIfPresent([String: Int].self, forKey: .drops)
        self.inventoryTarget = try container.decodeIfPresent(InventoryTarget.self, forKey: .inventoryTarget)
        self.report_to_penguin = try container.decodeIfPresent(Bool.self, forKey: .report_to_penguin) ?? false
        self.penguin_id = try container.decodeIfPresent(String.self, forKey: .penguin_id) ?? ""
        self.server = try container.decodeIfPresent(String.self, forKey: .server) ?? "CN"
        self.client_type = try container.decodeIfPresent(String.self, forKey: .client_type) ?? ""
        self.DrGrandet = try container.decodeIfPresent(Bool.self, forKey: .DrGrandet) ?? false
    }
}

extension FightConfiguration {
    var localizedExpiry: LocalizedStringResource { params.localizedExpiry }
}

extension FightConfiguration.Params {
    var localizedExpiry: LocalizedStringResource {
        switch medicine_expire_days {
        case 0: "不启用"
        case 1: "24小时内"
        case let d: "\(d - 1)天内"
        }
    }
}
