//
//  MiniGameLaunch.swift
//  MAA
//
//  Created by parity P17.1 on 2026/11/7.
//

import Foundation

/// 小游戏 CustomTask 的 params 形态（Core 51dac87 `CustomTask.cpp` 契约：
/// GUI 下发 `{task_names:[…], params:{…}}`，Core 在 `params` 一层下解析各
/// 插件专属键）。
enum MiniGameLaunch {
    /// T16 自动提升潜能：`auto_raise_potential.use_normal_token`——中控信物
    /// 不足的确认弹窗默认放弃提升，开启后改走消耗普通信物的分支。
    static func autoRaisePotential(useNormalToken: Bool) -> [String: Any] {
        ["auto_raise_potential": ["use_normal_token": useNormalToken]]
    }

    /// T12 活动商店黑名单：`event_shop.blacklist`（仅字符串、空串剔除）。
    /// 空名单返回 nil——Core 对空名单不注册 EventShop 插件，走默认购买流程，
    /// 显式传空数组与之等价但省一次覆盖。
    static func eventShop(blacklist: [String]) -> [String: Any]? {
        let names = blacklist
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        return ["event_shop": ["blacklist": names]]
    }

    // MARK: - P17-[d]（快照 82 清单②裁定：随 WPF 对齐，2026-11-09）

    /// 预设关键词的客户端语言桶：WPF `StartEventShop`（ToolboxViewModel.cs
    /// :3639-3646）按 ClientType 分派——「匹配语言由游戏客户端而非 GUI 语言
    /// 决定」。Mac 以 `MAAClientChannel.rawValue` 归并五桶：YoStarEN/JP/KR
    /// 直映、txwy=繁中、Official/Bilibili 及未知值回退简中（WPF default 分支同）。
    enum EventShopKeywordLanguage {
        case zhHans, zhHant, en, jp, kr
    }

    static func eventShopKeywordLanguage(channelRawValue: String) -> EventShopKeywordLanguage {
        switch channelRawValue {
        case "YoStarEN": .en
        case "YoStarJP": .jp
        case "YoStarKR": .kr
        case "txwy": .zhHant
        default: .zhHans
        }
    }

    /// 四类预设关键词（WPF :3639-3646 五语表逐字）：数据增补仪/数据增补条/
    /// 龙门币/家具零件。直接提交关键词，不经物品 ID 补全名（WPF 注释同）。
    static func eventShopPresetKeywords(
        language: EventShopKeywordLanguage
    ) -> (instrument: String, stick: String, lmd: String, furniturePart: String) {
        switch language {
        case .en:
            return ("Data Supplement Instrument", "Data Supplement Stick", "LMD", "Furniture Part")
        case .jp:
            return ("データ補完マシン", "データ補完チップ", "龍門幣", "家具")
        case .kr:
            return ("데이터 리더기", "데이터 메모리", "용문폐", "가구 부품")
        case .zhHant:
            return ("數據增補儀", "數據增補條", "龍門幣", "傢俱")
        case .zhHans:
            return ("数据增补仪", "数据增补条", "龙门币", "家具")
        }
    }

    /// 组合最终黑名单（WPF :3635-3656+:3668 同构）：Other 开关门控自定义列表
    /// （trim+剔空+Distinct 保序去重）；四类预设按开关追加于自定义之后、按
    /// instrument→stick→lmd→furniturePart 固定序；**收尾对最终合并列表整体
    /// Distinct**（S8-1-R3 中-1 勘正——WPF :3668 `Distinct().ToList()` 作用于
    /// 自定义+预设合并后的完整列表，首版误判为仅 Other 拆分列表）。
    static func eventShopBlacklist(
        custom: [String], otherEnabled: Bool,
        instrument: Bool, stick: Bool, lmd: Bool, furniturePart: Bool,
        channelRawValue: String
    ) -> [String] {
        var list: [String] = []
        if otherEnabled {
            var seen = Set<String>()
            for raw in custom {
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty, seen.insert(name).inserted {
                    list.append(name)
                }
            }
        }
        let keywords = eventShopPresetKeywords(
            language: eventShopKeywordLanguage(channelRawValue: channelRawValue))
        if instrument { list.append(keywords.instrument) }
        if stick { list.append(keywords.stick) }
        if lmd { list.append(keywords.lmd) }
        if furniturePart { list.append(keywords.furniturePart) }
        // WPF :3668：最终列表整体 Distinct（保序首现）。
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }
}
