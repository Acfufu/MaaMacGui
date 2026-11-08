//
//  OperBoxHistoryPayload.swift
//  MAA
//
//  Created by parity P14.1 on 2026/11/7.
//

import Foundation

/// A stable snapshot of fields actually emitted by OperBox, extended (schema v1
/// additive) with optional skill/mastery/module data that only the Yituliu OpenAPI
/// supplies — the recognition callback still does not carry them.
struct OperBoxHistoryPayload: Codable, Equatable, Sendable {
    struct Operator: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let own: Bool
        let name: String
        let rarity: Int
    }
    struct Skill: Codable, Equatable, Sendable {
        let id: String
        /// 专精等级 0-3。
        let level: Int
    }
    struct Equip: Codable, Equatable, Sendable {
        let id: String
        /// 模组分支（X/Y 等）。
        let type: String
        let level: Int
    }
    struct OwnedOperator: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let own: Bool
        let name: String
        let rarity: Int
        let elite: Int
        let level: Int
        let potential: Int
        /// 以下仅一图流来源携带；识别回调始终为 nil。
        let mainSkillLevel: Int?
        let skills: [Skill]?
        let equips: [Equip]?

        init(id: String, own: Bool, name: String, rarity: Int, elite: Int, level: Int, potential: Int,
             mainSkillLevel: Int? = nil, skills: [Skill]? = nil, equips: [Equip]? = nil) {
            self.id = id
            self.own = own
            self.name = name
            self.rarity = rarity
            self.elite = elite
            self.level = level
            self.potential = potential
            self.mainSkillLevel = mainSkillLevel
            self.skills = skills
            self.equips = equips
        }
    }
    let done: Bool
    let allOperators: [Operator]
    let ownedOperators: [OwnedOperator]

    var isValid: Bool {
        done && !allOperators.isEmpty && !ownedOperators.isEmpty && Set(allOperators.map(\.id)).count == allOperators.count
            && Set(ownedOperators.map(\.id)).count == ownedOperators.count
            && allOperators.allSatisfy { !$0.id.isEmpty && !$0.name.isEmpty && $0.rarity >= 0 }
            && ownedOperators.allSatisfy {
                !$0.id.isEmpty && !$0.name.isEmpty && $0.rarity >= 0
                    && $0.elite >= 0 && $0.level >= 0 && $0.potential >= 0
                    && ($0.mainSkillLevel == nil || (1...7).contains($0.mainSkillLevel!))
                    && ($0.skills == nil || $0.skills!.allSatisfy { !$0.id.isEmpty && (0...3).contains($0.level) })
                    && ($0.equips == nil || $0.equips!.allSatisfy { !$0.id.isEmpty && !$0.type.isEmpty && $0.level >= 0 })
            }
    }
}
