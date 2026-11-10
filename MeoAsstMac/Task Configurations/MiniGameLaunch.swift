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
}
