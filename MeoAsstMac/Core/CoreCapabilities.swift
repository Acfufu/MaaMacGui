//
//  CoreCapabilities.swift
//  MeoAsstMac
//

import Foundation

/// 按已加载产物推导的 Core 可用能力快照（P02.2）。
///
/// 推导只读资源树与 Core 版本字符串，不触 Core 句柄，纯函数可用
/// fixture 矩阵直接测试。刷新点与 SecretFront 可用性缓存一致：
/// `loadResource`/`reloadResources` 完成后与 `updateChannel` 同步段。
struct CoreCapabilities: Equatable, Sendable {
    /// 作战倍率上限（P01.1 语义）：旧资源 6，新资源与缺省 10。
    var seriesUpperBound: Int
    /// 隐秘战线可用：区服 + 资源判据复用 `SecretFrontConfiguration.unavailableReason`。
    var secretFrontAvailable: Bool
    /// 基建回收站产物上报（B15）可用。Core 侧该插件在 InfrastTask.cpp:47
    /// 无条件注册——需 pin ≥ 51dac87（P02.1 已升级至此，旧 pin 4d948320
    /// 的检出尚无该插件）。资源节点 `InfrastRewardRecycleProduct`
    /// verify 通过即生效，故判据 = 资源节点就绪 && Core 版本可读（版本
    /// 拿不到时保守关断）。已知误报窗口：coreVersion 接通后若资源 OTA
    /// 新于 pin（资源节点在、核心插件缺），recycle 会误报 true；追加
    /// "pin 核心插件存在性校验"可消除，但需要构建期插件清单通道，成本
    /// 未挂钩前先记录于任务证据 run.json（当前被 coreVersion:nil 掩盖）。
    var recycleProductAvailable: Bool
    /// Core 达到 GUI 内置期望（当前语义：能读到 Core 版本号即视为达标；
    /// Maa.swift 已暴露 MAAHandle.coreVersion()（P29.1），装载路径尚未接线
    /// 仍传 nil → false——接线即可提升门控，台账 P29-[e]）。
    var minimumCoreVersionMet: Bool

    /// 资源未知时的保守初值：布尔能力全关；seriesUpperBound 按 P01.1
    /// 的缺省论证保留 10（缺 tasks 定义按新 UI 处理）。
    static let conservativeDefault = CoreCapabilities(
        seriesUpperBound: 10,
        secretFrontAvailable: false,
        recycleProductAvailable: false,
        minimumCoreVersionMet: false
    )

    /// 资源根缺失或不可读时布尔能力一律 false（N12 边界：错误资源不得
    /// 越过门控——探测直接读盘，加载失败留下的残缺树自然判不可用）。
    ///
    /// - Parameters:
    ///   - resourceRoot: SecretFront 完整性判据根（base 根，历史语义；
    ///     MAAViewModel 传 `secretFrontResourceRoot()`。不读 OTA cache 根：
    ///     cache 只承载 tasks/StageActivity 增量，无 MiniGame template）。
    ///   - tasksResourceRoot: series/recycle 的 tasks 定义根（覆盖层感知，
    ///     由 `effectiveResourceRoot` 解析；缺省回落 `resourceRoot`——
    ///     旧资源 OldMethodFlag 在 global 覆盖层，拿 base 根会把 YoStarEN
    ///     误报成 10）。
    static func derive(
        coreVersion: String?, resourceRoot: URL?, channel: MAAClientChannel,
        tasksResourceRoot: URL? = nil
    ) -> CoreCapabilities {
        let version = coreVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        let versionMet = !(version?.isEmpty ?? true)
        let tasksRoot = tasksResourceRoot ?? resourceRoot

        return CoreCapabilities(
            seriesUpperBound: FightConfiguration.seriesUpperBound(resourceRoot: tasksRoot),
            secretFrontAvailable: SecretFrontConfiguration.unavailableReason(
                isGlobalChannel: channel.isGlobal,
                resourceRoot: { resourceRoot }
            ) == nil,
            recycleProductAvailable: versionMet && hasRecycleProductNode(resourceRoot: tasksRoot),
            minimumCoreVersionMet: versionMet
        )
    }

    /// 与 MAAViewModel.loadResource(channel:) 同源的覆盖层感知根解析：按
    /// OTA 缓存 → 外部资源(preferUser) → 内置资源的加载顺序取首个含 tasks
    /// 定义的根；国际服优先 global 覆盖层（旧倍率 flag 在覆盖层）。
    /// FightSettingsView 的 series 上限与 derive 的 series/recycle 判据
    /// 共用本解析，保证两处口径一致。纯函数（根列表由调用方注入）。
    static func effectiveResourceRoot(
        channel: MAAClientChannel,
        cacheRoot: URL?,
        userRoot: URL?,
        bundleRoot: URL?
    ) -> URL? {
        [cacheRoot, userRoot, bundleRoot].lazy.compactMap { base -> URL? in
            guard let base else { return nil }
            let resource = base.appendingPathComponent("resource")
            let candidate = channel.isGlobal
                ? resource.appendingPathComponent("global")
                    .appendingPathComponent(channel.rawValue)
                    .appendingPathComponent("resource")
                : resource
            let hasTasks = ["tasks/tasks.json", "tasks.json"].contains {
                FileManager.default.fileExists(atPath: candidate.appendingPathComponent($0).path)
            }
            return hasTasks ? candidate : nil
        }.first
    }

    /// 资源节点探测，风格与 `FightConfiguration.seriesUpperBound` 一致：
    /// 在 tasks 定义（tasks.json / tasks/tasks.json）里查顶层键
    /// `InfrastRewardRecycleProduct`。
    private static func hasRecycleProductNode(resourceRoot: URL?) -> Bool {
        guard let resourceRoot else { return false }
        for path in ["tasks.json", "tasks/tasks.json"] {
            guard let data = try? Data(contentsOf: resourceRoot.appendingPathComponent(path)),
                let tasks = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            if tasks["InfrastRewardRecycleProduct"] != nil { return true }
        }
        return false
    }
}
