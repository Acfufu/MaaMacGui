//
//  FightConfiguration.swift
//  MAA
//
//  Created by hguandl on 16/4/2023.
//

import Foundation

/// F20 关卡重置策略（upstream FightStageResetMode.Current/Ignore）。
/// current=已轮换出目录的活动形主选重置为「当前/上次」（上游缺省）；
/// ignore=保留原值（Mac 缺省=历史行为）。
enum FightStageResetMode: String, Codable, Hashable, CaseIterable {
    case current
    case ignore
}

struct FightConfiguration: MAATaskConfiguration {
    var type: MAATaskType { .Fight }

    var stage: String
    /// F05 备选关卡（upstream FightTask.UseOptionalStage/StagePlan）：启用后
    /// 自上而下取第一个开放候选（stage 为首选，其后为备选）；全部关闭时
    /// 明确跳过本任务，而非代理失败后换关。Core 契约不变——只下发解析结果。
    var useOptionalStage: Bool = false
    var optionalStages: [String] = []
    /// F06 每周执行日（upstream FightTask.UseWeeklySchedule/WeeklySchedule）：
    /// nil=不启用（每天执行）；非 nil=仅勾选的游戏日星期执行。星期为 HGCalendar
    /// 口径（0=周日…6=周六，与 FightStage 星期表同源），空数组=每周全跳（用户
    /// 显式选择，上游 WeeklySchedule 全 false 等价合法态）。GUI 侧门控，不下发
    /// Core 参数（上游同样只在任务序列化时跳过并记日志）。
    var weeklyDays: [Int]? = nil
    /// F20 关卡重置策略（upstream FightTask.StageResetMode）。旧数据缺键解码
    /// .ignore（Mac 历史行为=从不改写存量选择，避免迁移暗改）；上游缺省为
    /// .current——divergence 随实现记录。
    var stageResetMode: FightStageResetMode = .ignore
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

        if useOptionalStage, !optionalStages.isEmpty {
            parts.append(String(localized: "备选") + "×\(optionalStages.count)")
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

    // MARK: 备选关卡（F05）

    /// 备选计划的解析结果。语义对齐 upstream FightTask 序列化（ISerialize）：
    /// 全部候选关闭 → 跳过本任务；选中常驻关卡且其后仍有候选 → 截断提示。
    struct StagePlanResolution: Equatable {
        enum Outcome: Equatable {
            /// 下发解析后的关卡（未启用备选时即原 stage）。
            case dispatch(stage: String)
            /// 启用备选但全部候选今日关闭：跳过本任务并记录。
            case skipAllClosed
        }

        let outcome: Outcome
        /// 被选中的常驻候选（当前/上次、剿灭、1-7、目录外关卡）其后仍有备选时,
        /// 记录该候选——后备选永远不会被执行。
        let truncatedAfter: String?
    }

    /// 自上而下解析第一个开放候选。开放判定与可选目录同源（StageCatalog.
    /// isSelectable），叠加一条上游口径：目录外的活动形码（^[A-Za-z]{2}-\d{1,2}$，
    /// 如 YW-8）按「已过期活动」判关——轮换移除或版本门槛滤除后不得再当作
    /// 回退候选下发死关卡（upstream StageManager 对未知活动形码的默认态）。
    /// 其余目录外关卡（主线/手输/特殊导航）维持 fail-open（F19 存量可连性）。
    /// 未启用备选时行为不变——原样下发 stage（存量档案零迁移、手输/特殊
    /// 导航语义不受当日开放性影响）。
    func resolvedStagePlan(at date: Date, catalog: StageCatalog) -> StagePlanResolution {
        guard useOptionalStage else {
            return StagePlanResolution(outcome: .dispatch(stage: stage), truncatedAfter: nil)
        }

        let candidates = ([stage] + optionalStages).map(Self.normalizedStage)
        let entries = catalog.entries(at: date)
        let picked = candidates.first { code in
            if let entry = entries.first(where: { $0.code == code }) {
                return entry.isOpen
            }
            // 目录外：fail-open，但活动形码视为过期活动。
            return !Self.isExpiredActivityShape(code)
        }
        guard let picked else {
            return StagePlanResolution(outcome: .skipAllClosed, truncatedAfter: nil)
        }

        var truncatedAfter: String?
        if let index = candidates.firstIndex(of: picked), index < candidates.count - 1,
            Self.isPermanentStage(picked, catalog: catalog, at: date)
        {
            truncatedAfter = picked
        }
        return StagePlanResolution(outcome: .dispatch(stage: picked), truncatedAfter: truncatedAfter)
    }

    /// 上游 StageManager 口径：目录外但呈活动形（两字母-数字，如 YW-8）的
    /// 关卡按已过期活动处理。主线（1-7/H10-1-Hard）、特殊名（JT8-2/
    /// AveMujica-8/SSReopen-*）不匹配此形态。
    static func isExpiredActivityShape(_ code: String) -> Bool {
        code.range(of: "^[A-Za-z]{2}-[0-9]{1,2}$", options: .regularExpression) != nil
    }

    /// 常驻关卡判定（upstream IsPermanentStage：无星期限制且非限时活动）。
    /// 当前/上次、剿灭、1-7、常开资源关（LS-6 类，无星期表）与目录外关卡
    /// 常驻；带星期表的资源收集与带窗口的活动关卡非常驻——即便今日开放
    /// 也不截断后备选。目录外活动形码按过期活动处理，非常驻。
    static func isPermanentStage(_ code: String, catalog: StageCatalog, at date: Date) -> Bool {
        if code.isEmpty || code == "Annihilation" || code == "1-7" { return true }
        if FightStage.isAlwaysOpenResource(code) { return true }
        guard let entry = catalog.entries(at: date).first(where: { $0.code == code }) else {
            return !Self.isExpiredActivityShape(code)
        }
        switch entry.group {
        case .currentAndLast, .annihilation: return true
        case .activity, .resourceCollection: return false
        }
    }

    // MARK: 每周执行日（F06）

    /// 今日（调用方按区服游戏日历换算星期）是否执行。nil=不启用=每天执行；
    /// 启用后仅勾选的星期执行，未勾选星期由运行入口跳过并记录。
    func isScheduled(on weekday: Int) -> Bool {
        weeklyDays?.contains(weekday) ?? true
    }

    // MARK: 关卡重置策略（F20）

    /// 未启用备选时，主选应重置为「当前/上次」则返回原关卡码（供日志），否则 nil。
    /// 触发条件=策略 .current 且主选为目录外活动形码（已轮换活动，沿用
    /// isExpiredActivityShape 口径；上游 RefreshUI 对不在关卡列表的项重置，
    /// 主线/特殊名在上游列表内故不触发）。目录内今日关闭不重置——关闭面由
    /// 备选解析/跳过处理。启用备选时由 resolvedStagePlan 接管，不改写休眠
    /// 备选数据（P06.1 Q3：回开备选即恢复完整计划）。
    func resetStageForDispatch(at date: Date, catalog: StageCatalog) -> String? {
        guard stageResetMode == .current, !useOptionalStage else { return nil }
        let code = Self.normalizedStage(stage)
        guard Self.isExpiredActivityShape(code) else { return nil }
        guard !catalog.entries(at: date).contains(where: { $0.code == code }) else { return nil }
        return code
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

/// 活动关卡 Drop 字段的展示口径（P05.2）：纯数字按物品 ID 查已加载物品表；
/// 表未加载或查不到时原样返回，不伪造物品名。
@MainActor
enum StageDropLabel {
    static func text(_ raw: String) -> String {
        guard !raw.isEmpty, raw.allSatisfy(\.isNumber) else { return raw }
        return FightConfiguration.dropItems.first { $0.id == raw }?.item.name ?? raw
    }
}

private enum LegacyCodingKeys: String, CodingKey {
    case expiring_medicine
}

extension FightConfiguration {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.stage = try container.decodeIfPresent(String.self, forKey: .stage) ?? ""
        self.useOptionalStage = try container.decodeIfPresent(Bool.self, forKey: .useOptionalStage) ?? false
        self.optionalStages = try container.decodeIfPresent([String].self, forKey: .optionalStages) ?? []
        self.weeklyDays = try container.decodeIfPresent([Int].self, forKey: .weeklyDays)
        self.stageResetMode = try container.decodeIfPresent(FightStageResetMode.self, forKey: .stageResetMode) ?? .ignore
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
