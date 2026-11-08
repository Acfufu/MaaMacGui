//
//  DepotMaintainConfiguration.swift
//  MAA
//

import Foundation

/// 库存保持单条计划（upstream DepotMaintainTask.Plan 同构）：指定关卡与目标材料，
/// 达到目标库存即停；药剂/源石预算按计划独立勾选。
/// 旧档案缺键解码为全空（未配置的计划在预检中按 invalid/zero 跳过并记录）。
struct DepotMaintainPlan: Codable, Hashable, Sendable {
    var stage: String = ""
    var dropID: String = ""
    var dropCount: Int = 0
    var useMedicine: Bool = false
    var medicineCount: Int = 0
    var useStone: Bool = false
    var stoneCount: Int = 0

    enum CodingKeys: String, CodingKey {
        case stage, dropID, dropCount, useMedicine, medicineCount, useStone, stoneCount
    }

    /// 计划条目缺键按 WPF record 构造器缺省解码（部分写入的条目不得让整档失效）。
    init() {}

    init(stage: String = "", dropID: String = "", dropCount: Int = 0,
         useMedicine: Bool = false, medicineCount: Int = 0,
         useStone: Bool = false, stoneCount: Int = 0) {
        self.stage = stage
        self.dropID = dropID
        self.dropCount = dropCount
        self.useMedicine = useMedicine
        self.medicineCount = medicineCount
        self.useStone = useStone
        self.stoneCount = stoneCount
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stage = try c.decodeIfPresent(String.self, forKey: .stage) ?? ""
        dropID = try c.decodeIfPresent(String.self, forKey: .dropID) ?? ""
        dropCount = try c.decodeIfPresent(Int.self, forKey: .dropCount) ?? 0
        useMedicine = try c.decodeIfPresent(Bool.self, forKey: .useMedicine) ?? false
        medicineCount = try c.decodeIfPresent(Int.self, forKey: .medicineCount) ?? 0
        useStone = try c.decodeIfPresent(Bool.self, forKey: .useStone) ?? false
        stoneCount = try c.decodeIfPresent(Int.self, forKey: .stoneCount) ?? 0
    }
}

/// GUI composite task. This name must never be submitted to AsstAppendTask——
/// 分发时展开为可选的前置仓库识别 + 逐计划战斗任务（见 MAAViewModel 序列化）。
/// 语义对齐 upstream DepotMaintainTask（dev-v2 d75bf9a）；第三方上报/区服/客户端
/// 为任务级字段（WPF 取全局设置——Mac 沿用 F16/F17 任务级惯例，divergence 记录）。
struct DepotMaintainConfiguration: MAATaskConfiguration {
    var type: MAATaskType { .DepotMaintain }

    var updateDepot = true
    var isStageManually = false
    /// 活动期间跳过整个任务（upstream SkipDuringActivity）。
    var skipDuringActivity = false
    /// 资源全开放期间跳过整个任务（upstream SkipDuringResourceCollection）。
    var skipDuringResourceCollection = false
    /// 仅下发第一个库存不足且当日可执行的计划，补满后由下次运行继续后续计划。
    var onlyFirstInsufficientPlan = false
    /// 下发时按库存达成率（当前÷目标，升序）临时排序；配置列表顺序保持不变。
    var sortByProgress = false
    /// 统计芯片组库存时把对应双芯片按合成配方折算计入（每个双芯片折算为 2 个芯片组）。
    var countDualChipAsChipPack = false
    /// 使用 AUTO 代理倍率（Series = 0）；关闭时按 1 倍刷取。
    var useAutoSeries = false
    var useMedicine = true
    var useStone = true
    /// 使用临期理智药（upstream UseExpiringMedicine，固定 2 天阈值）。
    var useExpiringMedicine = false

    var plans: [DepotMaintainPlan] = []

    var report_to_penguin = false
    var penguin_id = ""
    var report_to_yituliu = false
    var yituliu_id = ""
    var server = "CN"
    var client_type = ""

    var title: String { String(localized: "库存保持") }
    var subtitle: String {
        plans.isEmpty ? String(localized: "未配置计划") : String(localized: "\(plans.count) 项计划")
    }
    var summary: String {
        var parts = [String]()
        if onlyFirstInsufficientPlan { parts.append(String(localized: "仅首个不足")) }
        if sortByProgress { parts.append(String(localized: "按达成率排序")) }
        if skipDuringActivity { parts.append(String(localized: "活动跳过")) }
        if countDualChipAsChipPack { parts.append(String(localized: "芯片折算")) }
        return parts.joined(separator: ";")
    }
    var projectedTask: MAATask { .depotMaintain(self) }
    var params: Self { self }

    enum CodingKeys: String, CodingKey {
        case updateDepot, isStageManually, skipDuringActivity, skipDuringResourceCollection
        case onlyFirstInsufficientPlan, sortByProgress, countDualChipAsChipPack
        case useAutoSeries, useMedicine, useStone, useExpiringMedicine, plans
        case report_to_penguin, penguin_id, report_to_yituliu, yituliu_id, server, client_type
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        updateDepot = try c.decodeIfPresent(Bool.self, forKey: .updateDepot) ?? true
        isStageManually = try c.decodeIfPresent(Bool.self, forKey: .isStageManually) ?? false
        skipDuringActivity = try c.decodeIfPresent(Bool.self, forKey: .skipDuringActivity) ?? false
        skipDuringResourceCollection = try c.decodeIfPresent(Bool.self, forKey: .skipDuringResourceCollection) ?? false
        onlyFirstInsufficientPlan = try c.decodeIfPresent(Bool.self, forKey: .onlyFirstInsufficientPlan) ?? false
        sortByProgress = try c.decodeIfPresent(Bool.self, forKey: .sortByProgress) ?? false
        countDualChipAsChipPack = try c.decodeIfPresent(Bool.self, forKey: .countDualChipAsChipPack) ?? false
        useAutoSeries = try c.decodeIfPresent(Bool.self, forKey: .useAutoSeries) ?? false
        useMedicine = try c.decodeIfPresent(Bool.self, forKey: .useMedicine) ?? true
        useStone = try c.decodeIfPresent(Bool.self, forKey: .useStone) ?? true
        useExpiringMedicine = try c.decodeIfPresent(Bool.self, forKey: .useExpiringMedicine) ?? false
        plans = try c.decodeIfPresent([DepotMaintainPlan].self, forKey: .plans) ?? []
        report_to_penguin = try c.decodeIfPresent(Bool.self, forKey: .report_to_penguin) ?? false
        penguin_id = try c.decodeIfPresent(String.self, forKey: .penguin_id) ?? ""
        report_to_yituliu = try c.decodeIfPresent(Bool.self, forKey: .report_to_yituliu) ?? false
        yituliu_id = try c.decodeIfPresent(String.self, forKey: .yituliu_id) ?? ""
        server = try c.decodeIfPresent(String.self, forKey: .server) ?? "CN"
        client_type = try c.decodeIfPresent(String.self, forKey: .client_type) ?? ""
    }
}
