//
//  DepotMaintainPlanner.swift
//  MAA
//

import Foundation

/// 库存保持计划规划核心（I05-I10/I12 模型层）。
/// 语义对齐 upstream DepotMaintainTaskUserControlModel.SerializeTask（dev-v2 d75bf9a）：
/// 预检空库存按 0 计（识别回填后的重算负责纠正，upstream 同口径下发后重算）；
/// 无效计划/零目标/已达标/关卡未开放逐条跳过；SortByProgress 仅调整下发顺序
/// （配置列表顺序保持不变）；OnlyFirstInsufficientPlan 只评估到第一个不足计划。
enum DepotMaintainPlanner {
    /// 单计划预检结论。index 为配置列表下标，日志序号 = index + 1（与 UI 列表对应，
    /// 排序后仍回写原下标——upstream 以原索引写 TaskId 与日志序号）。
    enum PlanOutcome: Equatable {
        /// 库存不足：需补 need 个（当前 + 可选折算 = current）。
        case dispatched(need: Int, current: Int)
        /// 已达标，跳过（upstream PlanInventoryEnough）。
        case enough(current: Int)
        /// 未选材料（upstream PlanInvalidDropItem）。
        case invalidDrop
        /// 目标为 0（upstream PlanZeroDropCount）。
        case zeroDropCount
        /// 未选关卡（upstream PlanNoStage）。
        case noStage
        /// 当日不可执行（upstream PlanStageNotOpen）。
        case stageClosed
    }

    struct Evaluation: Equatable {
        let index: Int
        let plan: DepotMaintainPlan
        let outcome: PlanOutcome
    }

    /// 任务级跳过判定（upstream SerializeTask 前置两个开关）：活动进行中或资源
    /// 全开放期间跳过整个库存保持任务。判定与 medicineWindow 同源（活动窗口
    /// 原始数据，不经目录版本门槛）；常开资源关（LS-6）不计入资源全开放
    /// （upstream IsResourceCollectionOpen 只看专用窗口）。
    enum TaskSkip: Equatable {
        case activityOpen
        case resourceCollectionOpen
    }

    static func taskLevelSkip(config: DepotMaintainConfiguration, at date: Date, activities: MAAStageActivity?) -> TaskSkip? {
        if config.skipDuringActivity,
            activities?.sideStoryStage?.values.contains(where: { $0.Activity?.contains(date) == true }) == true {
            return .activityOpen
        }
        if config.skipDuringResourceCollection, activities?.resourceCollection?.contains(date) == true {
            return .resourceCollectionOpen
        }
        return nil
    }

    // MARK: 双芯片折算（I10）

    /// 双芯片判定（upstream IsDualChip：配方含芯片助剂 32001）。
    static func isDualChip(formula: [String: Int]?) -> Bool {
        (formula?["32001"] ?? 0) > 0
    }

    /// 目标物品按双芯片配方的折算增量：仓库中以它为材料的双芯片数量 × 配方消耗数之和
    /// （upstream GetDualChipConversion；当前数据每个双芯片折算为 2 个芯片组）。
    /// formulas = itemID → 配方（材料ID → 消耗数），来源 item_index.json formula 字段。
    static func dualChipConversion(for dropID: String, inventory: [String: Int], formulas: [String: [String: Int]]) -> Int {
        var conversion = 0
        for (productID, formula) in formulas where isDualChip(formula: formula) {
            if let consumed = formula[dropID], consumed > 0 {
                conversion += max(inventory[productID] ?? 0, 0) * consumed
            }
        }
        return conversion
    }

    /// 计划生效库存：原始数量 + 可选双芯片折算（负值按 0 计，upstream 以 Count >= 0 过滤）。
    static func effectiveCount(of plan: DepotMaintainPlan, inventory: [String: Int],
                               formulas: [String: [String: Int]], chipConversion: Bool) -> Int {
        let raw = max(inventory[plan.dropID] ?? 0, 0)
        guard chipConversion else { return raw }
        return raw + dualChipConversion(for: plan.dropID, inventory: inventory, formulas: formulas)
    }

    /// 库存达成率（当前÷目标）。无效计划（未选材料或目标为 0）返回 nil——排序置末尾
    /// （upstream double.MaxValue 口径）；未识别过的材料按 0 计。
    static func progress(of plan: DepotMaintainPlan, inventory: [String: Int],
                         formulas: [String: [String: Int]], chipConversion: Bool) -> Double? {
        guard !plan.dropID.isEmpty, plan.dropCount > 0 else { return nil }
        let current = effectiveCount(of: plan, inventory: inventory, formulas: formulas, chipConversion: chipConversion)
        return Double(current) / Double(plan.dropCount)
    }

    // MARK: 预检与下发顺序（I07/I08/I09）

    /// 全量预检。返回按下发顺序排列的评估：
    /// - SortByProgress 开启且计划数 > 1 时按达成率升序重排（达成率相等保持配置
    ///   顺序——Swift sort 不稳定，显式以下标决胜实现 upstream LINQ 稳定序）；
    ///   无效计划置末尾。仅影响下发顺序，Evaluation.index 保持原配置下标。
    /// - OnlyFirstInsufficientPlan 开启时，首个 dispatched 之后的计划不再评估
    ///   （upstream「其后计划本轮不评估也不输出日志」）。
    /// - 预检顺序对齐 upstream：材料 → 目标 → 已达标 → 关卡（已达标先于开放判定）。
    static func evaluate(config: DepotMaintainConfiguration, inventory: [String: Int],
                         formulas: [String: [String: Int]] = [:],
                         isStageOpen: (String) -> Bool = { _ in true }) -> [Evaluation] {
        var order = Array(config.plans.enumerated())
        if config.sortByProgress, config.plans.count > 1 {
            order.sort { lhs, rhs in
                switch (progress(of: lhs.element, inventory: inventory, formulas: formulas, chipConversion: config.countDualChipAsChipPack),
                        progress(of: rhs.element, inventory: inventory, formulas: formulas, chipConversion: config.countDualChipAsChipPack)) {
                case let (l?, r?):
                    return l == r ? lhs.offset < rhs.offset : l < r
                case (nil, _?):
                    return false
                case (_?, nil):
                    return true
                case (nil, nil):
                    return lhs.offset < rhs.offset
                }
            }
        }

        var evaluations: [Evaluation] = []
        for (index, plan) in order {
            if plan.dropID.isEmpty {
                evaluations.append(Evaluation(index: index, plan: plan, outcome: .invalidDrop))
                continue
            }
            if plan.dropCount <= 0 {
                evaluations.append(Evaluation(index: index, plan: plan, outcome: .zeroDropCount))
                continue
            }
            let current = effectiveCount(of: plan, inventory: inventory, formulas: formulas, chipConversion: config.countDualChipAsChipPack)
            if plan.dropCount - current <= 0 {
                evaluations.append(Evaluation(index: index, plan: plan, outcome: .enough(current: current)))
                continue
            }
            if plan.stage.isEmpty {
                evaluations.append(Evaluation(index: index, plan: plan, outcome: .noStage))
                continue
            }
            guard isStageOpen(plan.stage) else {
                evaluations.append(Evaluation(index: index, plan: plan, outcome: .stageClosed))
                continue
            }
            evaluations.append(Evaluation(index: index, plan: plan, outcome: .dispatched(need: plan.dropCount - current, current: current)))
            if config.onlyFirstInsufficientPlan { break }
        }
        return evaluations
    }

    /// 由预检结论合成待下发的战斗任务（upstream AsstFightTask 构造同构）：
    /// drops = {材料: need}、times = Int32.max（Core 契约：刷到目标量为止）、
    /// 药/石按计划勾选且全局面开启、临期药窗口固定 2 天或关闭、倍率 AUTO=0/单倍=1。
    /// 第三方上报与区服/客户端取任务级字段（WPF 取全局设置——divergence 记录）。
    static func dispatchFight(for plan: DepotMaintainPlan, config: DepotMaintainConfiguration, need: Int) -> FightConfiguration {
        FightConfiguration(
            stage: FightConfiguration.normalizedStage(plan.stage),
            medicine: config.useMedicine && plan.useMedicine ? plan.medicineCount : 0,
            medicine_expire_days: config.useExpiringMedicine ? DepotMaintainConfiguration.expiringMedicineDays : 0,
            stone: config.useStone && plan.useStone ? plan.stoneCount : 0,
            times: Int(Int32.max),
            series: config.useAutoSeries ? 0 : 1,
            drops: [plan.dropID: need],
            report_to_penguin: config.report_to_penguin,
            penguin_id: config.penguin_id,
            report_to_yituliu: config.report_to_yituliu,
            yituliu_id: config.yituliu_id,
            server: config.server,
            client_type: config.client_type,
            DrGrandet: false)
    }
}

extension DepotMaintainConfiguration {
    /// 临期药阈值（天）——upstream DepotMaintainTask.ExpiringMedicineDays。
    static let expiringMedicineDays = 2
}
