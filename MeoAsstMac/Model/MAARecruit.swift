//
//  MAARecruit.swift
//  MAA
//
//  Created by hguandl on 19/4/2023.
//

import Foundation

struct MAARecruit: Codable {
    let tags: [String]
    let level: Int
    let result: [MAARecruit.Result]

    struct Result: Codable {
        let tags: [String]
        let level: Int
        let opers: [MAARecruit.Operator]
    }

    struct Operator: Codable {
        /// Core RecruitResult 逐干员携带 id（AutoRecruitTask.cpp:590）；旧档案回放或
        /// 非 Core 来源可能缺失，缺失时不参与潜能标注（WPF 同为 null 容忍）。
        let id: String?
        let name: String
        let level: Int
    }
}

/// WPF RecruitmentShowPotential 的展示语义（ToolboxViewModel.UpdateRecruitResult）。
enum RecruitPotentialAnnotation: Equatable {
    /// 已持有；潜能 1-5（Core OperBox 模板域 2-6，识别缺省 1）。
    case rank(Int)
    /// 已持有满潜（pot 6）。
    case max
    /// 开启标注且持有数据可用，但该干员不在持有表。
    case newOper

    /// WPF 硬编码展示文本，逐字同构（含空格与标点），不参与本地化。
    var displayText: String {
        switch self {
        case .rank(let potential): return " ( \(potential) )"
        case .max: return " ( MAX )"
        case .newOper: return " ( !!! NEW !!! )"
        }
    }
}

extension MAARecruit.Result {
    struct AnnotatedOperator: Identifiable {
        let oper: MAARecruit.Operator
        /// nil = 不标注：开关关闭、无持有数据、无 id 或门控未命中。
        let annotation: RecruitPotentialAnnotation?

        var id: String { oper.id ?? oper.name }
        /// WPF 排序键：未标注与 NEW 按 -1 参与潜能升序。
        var sortPotential: Int {
            switch annotation {
            case .rank(let potential): return potential
            case .max: return 6
            case nil, .newOper: return -1
            }
        }
    }

    /// 公招结果潜能标注（R10）：
    /// - 门控 `showPotential && 持有数据可用 && 干员有 id && (组合星级 >= 4 || 干员 1 星)`；
    /// - 已持有 → 潜能，pot 6 → MAX，未持有 → NEW；
    /// - 排序 = 干员星级降序、潜能升序（-1 兜底），同序保持原相对位置（WPF 稳定序）。
    func annotatedOpers(
        potentialByID: [String: Int]?, showPotential: Bool
    ) -> [AnnotatedOperator] {
        let annotated = opers.enumerated().map { index, oper -> AnnotatedOperator in
            guard showPotential, let potentialByID,
                  let id = oper.id, !id.isEmpty,
                  level >= 4 || oper.level == 1
            else { return .init(oper: oper, annotation: nil) }
            guard let potential = potentialByID[id] else {
                return .init(oper: oper, annotation: .newOper)
            }
            return .init(oper: oper, annotation: potential >= 6 ? .max : .rank(potential))
        }
        return annotated.enumerated().sorted { lhs, rhs in
            if lhs.element.oper.level != rhs.element.oper.level {
                return lhs.element.oper.level > rhs.element.oper.level
            }
            if lhs.element.sortPotential != rhs.element.sortPotential {
                return lhs.element.sortPotential < rhs.element.sortPotential
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}
