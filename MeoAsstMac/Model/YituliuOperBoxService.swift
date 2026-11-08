//
//  YituliuOperBoxService.swift
//  MAA
//
//  Created on 2026/11/6.
//

import Foundation

/// 一图流第三方 OpenAPI 客户端（I04 只读练度导入）。
/// 鉴权为 `Authorization` 头直接携带 token；业务结果看响应体 `code` 而非 HTTP 状态码
/// （WPF YituliuApiService 同构：200 成功、20010 仅写入权限、20027 token 无效）。
/// token 只进请求头，绝不进入日志或错误信息。
struct YituliuOperBoxService: Sendable {
    enum TokenValidationResult: Equatable, Sendable {
        /// token 有效且具备读取权限。
        case valid
        /// token 有效但只有写入权限，无法读取。
        case writeOnly
        /// token 无效、失效或业务码未识别。
        case invalid
        /// 网络请求失败或响应不可解析。
        case networkError
    }

    enum FetchResult: Equatable, Sendable {
        case success(operatorCount: Int)
        case tokenEmpty
        case writeOnly
        case invalid
        /// 账号未绑定或未导入练度（含全部行不可用）；保留本地已有数据。
        case noData
        case networkError
    }

    struct OperatorInfo: Codable, Equatable, Sendable {
        struct Skill: Codable, Equatable, Sendable {
            let id: String
            let level: Int
        }
        struct Equip: Codable, Equatable, Sendable {
            let id: String
            let type: String?
        }

        let id: String
        let level: Int
        /// 精英化阶段（0~2）。
        let evolvePhase: Int
        let mainSkillLevel: Int
        /// 潜能等级（1~6）。
        let potentialRank: Int
        let skills: [Skill]?
        let equips: [Equip]?
    }

    struct Response: Codable, Equatable, Sendable {
        let code: Int
        let msg: String?
        let data: [OperatorInfo]?
    }

    static let operatorInfoURL = URL(string: "https://backend.yituliu.cn/open-api/operator/info")!
    static let codeSuccess = 200
    static let codeInsufficientPermissions = 20010
    static let codeInvalidCredentials = 20027

    /// 业务码 → 验证结论；未知码按无效处理（WPF ParseValidationResult 同构）。
    static func parseValidation(_ body: Response?) -> TokenValidationResult {
        switch body?.code {
        case codeSuccess: return .valid
        case codeInsufficientPermissions: return .writeOnly
        default: return .invalid
        }
    }

    /// 拉取干员练度；token 由调用方先判空（tokenEmpty 是纯本地结论，不发请求）。
    /// 失败不回退 Core 本地识别：开关与按钮是用户显式选择，静默回退会突然要求连接模拟器。
    func fetchOperatorInfo(
        token: String, session: URLSession = .shared, url: URL = Self.operatorInfoURL
    ) async -> (TokenValidationResult, [OperatorInfo]?) {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(token, forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return (.networkError, nil)
            }
            let body = try? JSONDecoder().decode(Response.self, from: data)
            let verdict = Self.parseValidation(body)
            return (verdict, verdict == .valid ? body?.data : nil)
        } catch {
            return (.networkError, nil)
        }
    }

    /// 一图流数据 → 历史快照等价面（WPF ConvertYituliuDataToDetails 同构）：
    /// 本地干员表查不到的 id（资源过旧）跳过；名字/星级来自 battle_data.json；
    /// 越界行（空 id、负值、elite>2、potential 越界）整行跳过，避免污染快照有效性。
    /// skills/equips 一图流可提供但 Mac 历史快照面不承载（差异入档）；done=true、own=true。
    /// 去重保留首个；结果可能为空（全部跳过时由调用方按 noData 处理，不落盘覆盖）。
    static func convert(
        _ data: [OperatorInfo], catalog: OperatorCatalog
    ) -> OperBoxHistoryPayload {
        var owned = [OperBoxHistoryPayload.OwnedOperator]()
        var seen = Set<String>()
        for oper in data {
            guard !seen.contains(oper.id),
                  let entry = catalog.operators[oper.id],
                  !oper.id.isEmpty, oper.level >= 0,
                  (0...2).contains(oper.evolvePhase),
                  (1...6).contains(oper.potentialRank)
            else { continue }
            seen.insert(oper.id)
            let operatorEntry = OperBoxHistoryPayload.OwnedOperator(
                id: oper.id, own: true, name: entry.name, rarity: entry.rarity,
                elite: oper.evolvePhase, level: oper.level, potential: oper.potentialRank)
            owned.append(operatorEntry)
        }
        let all = owned.map {
            OperBoxHistoryPayload.Operator(id: $0.id, own: true, name: $0.name, rarity: $0.rarity)
        }
        return OperBoxHistoryPayload(done: true, allOperators: all, ownedOperators: owned)
    }
}

/// battle_data.json 的干员名/星级最小读取面：一图流数据只有 id，名字与星级
/// 用本地资源表补全（WPF DataHelper.Operators 同位）。单文件内嵌各语言名字段。
struct OperatorCatalog: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        let name: String
        let rarity: Int
    }

    let operators: [String: Entry]

    private struct BattleData: Decodable {
        let chars: [String: Character]
        struct Character: Decodable {
            let name: String
            let nameEn: String?
            let nameJp: String?
            let nameKr: String?
            let nameTw: String?
            let rarity: Int

            enum CodingKeys: String, CodingKey {
                case name
                case nameEn = "name_en"
                case nameJp = "name_jp"
                case nameKr = "name_kr"
                case nameTw = "name_tw"
                case rarity
            }

            /// 首选语言字段缺失或为空时回退简体 name。
            func displayName(preferredKey: String?) -> String {
                let localized: String?
                switch preferredKey {
                case "name_en": localized = nameEn
                case "name_jp": localized = nameJp
                case "name_kr": localized = nameKr
                case "name_tw": localized = nameTw
                default: localized = nil
                }
                if let localized, !localized.isEmpty { return localized }
                return name
            }
        }
    }

    /// locale 标识符 → battle_data 名字字段；zh-Hans 与未知语言回退简体 `name`。
    static func languageKey(forLocaleIdentifier identifier: String) -> String? {
        if identifier.hasPrefix("en") { return "name_en" }
        if identifier.hasPrefix("ja") { return "name_jp" }
        if identifier.hasPrefix("ko") { return "name_kr" }
        if identifier.hasPrefix("zh-Hant") || identifier.hasPrefix("zh-TW") || identifier.hasPrefix("zh-HK") {
            return "name_tw"
        }
        return nil
    }

    /// 目录缺失或解析失败返回空表：调用方据此把结果转为 noData/空导入，不部分落盘。
    static func load(resourceDirectory: URL?, localeIdentifier: String) -> Self {
        guard let url = resourceDirectory?.appendingPathComponent("battle_data.json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(BattleData.self, from: data)
        else { return Self(operators: [:]) }
        let preferredKey = Self.languageKey(forLocaleIdentifier: localeIdentifier)
        var map = [String: Entry]()
        map.reserveCapacity(decoded.chars.count)
        for (id, character) in decoded.chars {
            let name = character.displayName(preferredKey: preferredKey)
            guard !name.isEmpty, character.rarity >= 0 else { continue }
            map[id] = Entry(name: name, rarity: character.rarity)
        }
        return Self(operators: map)
    }
}
