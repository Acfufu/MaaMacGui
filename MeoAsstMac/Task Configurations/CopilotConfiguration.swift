//
//  CopilotConfiguration.swift
//  MAA
//
//  Created by hguandl on 17/4/2023.
//

import Foundation
import Observation

struct CopilotConfiguration: Codable, Hashable {
    var enable = true

    var filename: String?

    struct CopilotItem: Codable, Hashable {
        let filename: String
        let nav_name_override: String?
        let is_raid: Bool
    }

    var copilot_list = [CopilotItem]()

    struct ParadoxListItem: Codable, Hashable {
        let id: Int
        let filename: String
    }

    /// ParadoxCopilot 专用：Core 的 ParadoxCopilotTask 只读 filename（单文件）
    /// 或 list（元素为 {id, filename}），不读 copilot_list。Optional 在合成
    /// Codable 下 nil 不编码，其余任务类型的 payload 保持不变。
    var list: [ParadoxListItem]?

    var loop_times = 1

    var use_sanity_potion = false

    var formation = false
    var formation_index = 0

    struct UserUnit: Codable, Hashable {
        /// C08 编辑面需要可变（params 编码面不变：仍只含 name/skill）。
        var name: String
        var skill: Int
    }

    var user_additional = [UserUnit]()

    var add_trust = false
    var ignore_requirements = false

    enum SupportUnitUsage: Int, CaseIterable, Codable {
        /// 不加助战干员
        case none = 0
        /// 如果仅缺一名干员则尝试补助战
        case whenNeeded = 1
        /// 如果仅缺一名干员则尝试补助战，如无缺失则随机加一个助战干员
        case random = 3
        /// 如果仅缺一名干员则尝试补助战，如无缺失则使用指定助战干员
        case specific = 2
    }

    var support_unit_usage = SupportUnitUsage.none
    var support_unit_name = ""

    /// C11 干员资料辅助编队：Core `OperBoxData.load` 消费的数据文件路径，
    /// 空/nil = 禁用（Core `use_operbox = !path.empty()`）。仅普通作业任务
    /// 下发（SSS/悖论任务不消费）。
    var operbox_data_path: String?
}

extension CopilotConfiguration.SupportUnitUsage: Identifiable {
    var id: Int {
        rawValue
    }
}

extension CopilotConfiguration.SupportUnitUsage: CustomStringConvertible {
    var description: String {
        switch self {
        case .none:
            return String(localized: "不借", comment: "")
        case .whenNeeded:
            return String(localized: "补漏", comment: "")
        case .specific:
            return String(localized: "指定", comment: "")
        case .random:
            return String(localized: "随机", comment: "")
        }
    }
}

struct VideoRecognitionConfiguration: Codable {
    var enable = true
    var filename: String

    var params: String? {
        try? jsonString()
    }
}

// MARK: - Copilot Compiler

/// Rejections produced while compiling copilot execution parameters (C16).
///
/// Every case is reported to the user through the log channel instead of
/// letting the start request silently do nothing.
enum CopilotCompileError: Error, Equatable {
    /// List mode: the list is empty or every entry is toggled off.
    case emptyList
    /// List mode: the active set carries no kind information.
    case missingKind
    /// Single-file mode: the selected content is not a copilot JSON.
    case unsupportedContent
    /// Referenced files are missing on disk; every missing path is reported.
    case missingFile([String])
    /// List mode: files whose on-disk kind differs from the set kind. Files
    /// that no longer parse as a copilot count as offenders: their kind cannot
    /// be confirmed to match the set.
    case mixedKind(expected: MAACopilot.Kind, offenders: [String])
}

extension CopilotCompileError {
    /// User-facing log line for this rejection.
    var logMessage: String {
        switch self {
        case .emptyList:
            return String(localized: "没有可运行的作业：请先在列表中勾选至少一个作业。")
        case .missingKind:
            return String(localized: "作业集缺少类型信息，请重新激活此作业集。")
        case .unsupportedContent:
            return String(localized: "所选内容不是可执行的作业文件。")
        case .missingFile(let files):
            return String(localized: "以下作业文件不存在：\(files.joined(separator: "、"))")
        case .mixedKind(let expected, let offenders):
            return String(
                localized: "以下作业与作业集类型（\(expected.displayName)）不符：\(offenders.joined(separator: "、"))")
        }
    }
}

/// Pure compiler that turns the copilot tab state into queueable task
/// parameters. It touches neither MaaCore nor any actor, so every rejection
/// path is validated before a task is queued.
enum CopilotCompiler {
    /// Core-free summary of the copilot tab state needed for compilation.
    struct Input {
        enum Selection {
            /// List mode: the set's kind and its toggleable entries.
            case list(kind: MAACopilot.Kind?, items: [Item])
            /// Single-file mode: the selected copilot file and its kind.
            case single(url: URL, kind: MAACopilot.Kind)
            /// Single-file mode: anything else (no selection, set, directory, invalid).
            case other
        }

        struct Item {
            let url: URL
            var isOn: Bool
            var isRaid: Bool?
            /// 激活期 mapLevelCode 的结果（集合列表自带）；nil = 无映射语境
            /// （直构/测试），此时 kind 判定回退到 `Kind(of:)` 前缀推断。
            var stageCode: String?
            /// 单行导航识别名覆盖（C10）；nil/空 = 不覆盖。
            var navOverride: String?

            init(
                url: URL, isOn: Bool, isRaid: Bool? = nil, stageCode: String? = nil,
                navOverride: String? = nil
            ) {
                self.url = url
                self.isOn = isOn
                self.isRaid = isRaid
                self.stageCode = stageCode
                self.navOverride = navOverride
            }
        }

        var selection: Selection
        var config = CopilotConfiguration()
    }

    /// One queueable append: a task type plus its params carrier.
    struct Output: Equatable {
        let type: MAATaskType
        let config: CopilotConfiguration
    }

    static func compile(
        _ input: Input
    ) -> Result<[Output], CopilotCompileError> {
        var config = input.config

        switch input.selection {
        case .list(let kind, let items):
            let enabled = items.filter(\.isOn)
            guard !enabled.isEmpty else {
                return .failure(.emptyList)
            }
            guard let kind else {
                return .failure(.missingKind)
            }

            let filenames = enabled.map { $0.url.path(percentEncoded: false) }
            let missing = filenames.filter { !FileManager.default.fileExists(atPath: $0) }
            guard missing.isEmpty else {
                return .failure(.missingFile(missing))
            }

            let offenders = zip(enabled, filenames).compactMap { item, filename -> String? in
                guard let copilot = MAACopilot(url: item.url) else {
                    // Not parseable as a copilot: its kind cannot be confirmed
                    // to match the set, so it is reported as an offender.
                    return filename
                }
                // Same source as the activation-time judgment: the mapped level
                // code rides on the item and is never re-inferred from a prefix.
                let itemKind = item.stageCode.map { copilot.kind(code: $0) }
                    ?? MAACopilot.Kind(of: copilot)
                return itemKind == kind ? nil : filename
            }
            guard offenders.isEmpty else {
                return .failure(.mixedKind(expected: kind, offenders: offenders))
            }

            config.filename = nil
            switch kind {
            case .regular:
                // CopilotTask 消费 copilot_list（每项可带 nav/is_raid；C10 单行
                // 编辑的突袭与导航覆盖在这里透传）。
                config.copilot_list = zip(enabled, filenames).map { item, filename in
                    .init(
                        filename: filename,
                        nav_name_override: item.navOverride.flatMap {
                            $0.isEmpty ? nil : $0
                        },
                        is_raid: item.isRaid ?? false)
                }
                return .success([Output(type: kind.taskType, config: config)])
            case .paradox:
                // ParadoxCopilotTask 消费 list（元素 {id, filename}），不读
                // copilot_list；id 从 1 起计数。
                config.copilot_list = []
                config.list = filenames.enumerated().map { offset, filename in
                    .init(id: offset + 1, filename: filename)
                }
                return .success([Output(type: kind.taskType, config: config)])
            case .sss:
                // SSSCopilotTask 只读 filename：按列表顺序逐个排单文件任务；
                // 同一文件的常态/磨难两行只排一次。
                config.copilot_list = []
                var seen = Set<String>()
                let orderedFilenames = enabled.compactMap { item -> String? in
                    let filename = item.url.path(percentEncoded: false)
                    return seen.insert(filename).inserted ? filename : nil
                }
                return .success(orderedFilenames.map { filename in
                    var taskConfig = config
                    taskConfig.filename = filename
                    return Output(type: kind.taskType, config: taskConfig)
                })
            }
        case .single(let url, let kind):
            let filename = url.path(percentEncoded: false)
            guard FileManager.default.fileExists(atPath: filename) else {
                return .failure(.missingFile([filename]))
            }
            config.filename = filename
            return .success([Output(type: kind.taskType, config: config)])
        case .other:
            return .failure(.unsupportedContent)
        }
    }
}

extension CopilotCompiler.Input {
    /// Summarizes the live copilot tab for the compiler. The context's live
    /// configuration（循环次数/编队/吃药/助战/自选干员）必须随行——此前委托
    /// 初始化只带 selection、config 落回默认值，UI 设置从未进入下发参数
    /// （P13-[c]，本增量修复）。
    init(context: CopilotContext) {
        // C08 门控（WPF EnableUserAdditional 同构）：关闭时不下发自选干员，
        // 名单本身保留在设置里。
        var carriedConfig = context.config
        if !context.enableUserAdditional {
            carriedConfig.user_additional = []
        }

        if context.category == .list {
            self.init(
                selection: .list(
                    kind: context.copilotSet?.kind,
                    items: context.copilotList.map { item in
                        .init(
                            url: item.url, isOn: item.isOn, isRaid: item.isRaid,
                            stageCode: item.stageCode, navOverride: item.navOverride)
                    }),
                config: carriedConfig)
        } else if case .copilot(let url, let kind, _) = context.content {
            self.init(selection: .single(url: url, kind: kind), config: carriedConfig)
        } else {
            self.init(selection: .other, config: carriedConfig)
        }
    }
}

enum CopilotCategory: String, CaseIterable {
    case bundled
    case external
    case list
}

@Observable final class CopilotContext {
    var config: CopilotConfiguration {
        didSet {
            guard oldValue != config else {
                return
            }
            CopilotPersistence.saveConfiguration(config)
        }
    }

    @ObservationIgnored
    @Defaults("CopilotContentCategory")
    var category = CopilotCategory.bundled

    /// C08 额外自选干员下发门控（WPF EnableUserAdditional 同构，GUI 侧开关，
    /// 不进任务参数；名单本身持久化在 CopilotConfiguration 里）。
    @ObservationIgnored
    @Defaults("CopilotEnableUserAdditional")
    var enableUserAdditional = false

    /// C11 干员资料辅助编队开关（WPF EnableOperBoxAssist 同构，GUI 侧；路径
    /// 在开始作业时由会话/历史快照写出后进参数）。
    @ObservationIgnored
    @Defaults("CopilotEnableOperBoxAssist")
    var enableOperBoxAssist = false

    init() {
        config = CopilotPersistence.loadConfiguration() ?? CopilotConfiguration()
    }

    struct ItemID: Hashable {
        let url: URL
        let isRaid: Bool?
    }

    @ObservationIgnored @MainActor private var contentUpdateTask: Task<Void, Never>?

    @MainActor var selection: ItemID? {
        didSet {
            guard oldValue != selection else {
                return
            }
            contentUpdateTask?.cancel()
            guard let url = selection?.url else {
                content = nil
                return
            }
            content = .pending
            contentUpdateTask = Task {
                let newContent = await Content(url: url)
                guard !Task.isCancelled else { return }
                content = newContent
                contentUpdateTask = nil
            }
        }
    }

    enum Content: Equatable {
        case pending
        case copilot(URL, MAACopilot.Kind, MAACopilot)
        case set(URL, CopilotSetData)
        case directory
        case invalid
    }

    private(set) var content: Content?

    struct CopilotSet {
        let kind: MAACopilot.Kind
        let data: CopilotSetData
        let url: URL
    }

    private(set) var copilotSet: CopilotSet?

    /// 本会话是否已尝试过列表恢复（C09 跨启动恢复的一次性闸门；UI 侧用它在
    /// 恢复完成前不把空的列表分类自动切走）。
    @ObservationIgnored private(set) var restoreAttempted = false

    struct ListItem: Identifiable {
        let url: URL
        let stageCode: String
        /// 持久化键：`copilotID#派生难度行`（0=常态行, 1=突袭/磨难行）。
        /// 同文件双行（集合 difficulty 3）靠后缀区分；行内 isRaid 编辑不改键。
        var memberID: String
        var isRaid: Bool?
        var isOn = false
        /// 单行导航识别名覆盖（C10）；nil = 不覆盖。
        var navOverride: String?

        init(
            url: URL, stageCode: String, memberID: String? = nil, isRaid: Bool? = nil,
            isOn: Bool = false, navOverride: String? = nil
        ) {
            self.url = url
            self.stageCode = stageCode
            self.memberID = memberID ?? url.lastPathComponent
            self.isRaid = isRaid
            self.isOn = isOn
            self.navOverride = navOverride
        }

        var id: ItemID {
            .init(url: url, isRaid: isRaid)
        }
    }

    var copilotList = [ListItem]() {
        didSet {
            if copilotList.isEmpty {
                copilotSet = nil
            }
            CopilotPersistence.saveListState(
                CopilotPersistence.capture(items: copilotList, setURL: copilotSet?.url))
        }
    }

    func canMoveRow(of id: ItemID, by delta: Int) -> Bool {
        guard let index = copilotList.firstIndex(where: { $0.id == id }) else {
            return false
        }
        return copilotList.indices.contains(index + delta)
    }

    func moveRow(of id: ItemID, by delta: Int) {
        guard canMoveRow(of: id, by: delta),
            let index = copilotList.firstIndex(where: { $0.id == id })
        else {
            return
        }
        copilotList.swapAt(index, index + delta)
    }

    /// C12 评价入口：当前选中的单个外部下载作业（文件名为纯数字，即作业站
    /// id）；列表模式与内置/本地文件返回 nil（WPF CouldLikeWebJson = id>0 同构）。
    var currentRateableCopilotID: Int? {
        guard category != .list, case .copilot(let url, _, _) = content,
            url.deletingLastPathComponent().standardizedFileURL
                == URL.externalCopilotDirectory.standardizedFileURL
        else {
            return nil
        }
        let stem = url.deletingPathExtension().lastPathComponent
        guard !stem.isEmpty, stem.allSatisfy({ $0.isASCII && $0.isNumber }), let id = Int(stem) else {
            return nil
        }
        return id
    }
}

extension CopilotContext {
    /// 激活作业集；返回派生清单（含逐成员跳过原因），nil = 集合不可派生。
    @discardableResult
    nonisolated(nonsending) func updateSet(at url: URL, set: CopilotSetData) async -> CopilotSetData.SetListing? {
        guard let listing = await set.copilotList(at: url) else {
            return nil
        }

        self.copilotSet = .init(kind: listing.kind, data: set, url: url)
        self.copilotList = listing.items
        return listing
    }

    @discardableResult
    nonisolated(nonsending) func updateSet(at url: URL) async -> CopilotSetData.SetListing? {
        guard let set = CopilotSetData(atDirectory: url) else {
            return nil
        }
        return await updateSet(at: url, set: set)
    }

    /// C09 跨启动恢复：重建上次激活的作业集并套用持久化的行状态与顺序。
    /// 一次性（`restoreAttempted` 闸门）；活态保护复查在全部 await 之后——派生
    /// 窗口内用户手工激活是合法操作，恢复收尾以当场状态为准（评审 P13-1-R3
    /// 中危-1：前置检查在悬点间会被绕过，手工激活现场连同存档被旧存档顶掉）。
    /// 降级恢复（有跳过成员）以合并式存档保留被跳过成员的归档行（评审中危-2：
    /// 整表覆写会把瞬时映射失败成员的 isOn/isRaid/navOverride 永久销毁，用户
    /// 刻意关掉的行下次恢复按派生缺省 isOn=true 回归并可静默执行）。
    @discardableResult
    nonisolated(nonsending) func restorePersistedList() async -> CopilotRestoreOutcome {
        guard !restoreAttempted else {
            return .none
        }
        restoreAttempted = true

        guard copilotList.isEmpty else {
            return .none
        }
        let archivedState = CopilotPersistence.loadListState()
        if archivedState == nil, CopilotPersistence.hasListStateData() {
            // 存档数据存在但解码失败 = 损坏，与"无存档"区分记因（评审低-2）。
            return .failed(.archiveCorrupt)
        }
        guard let state = archivedState, let setPath = state.setPath else {
            return .none
        }

        let url = URL(fileURLWithPath: setPath)
        guard let setData = CopilotSetData(atDirectory: url),
            let listing = await setData.copilotList(at: url)
        else {
            return .failed(.setUnreadable)
        }

        // 活态保护复查（悬点后）：派生窗口内用户手工激活（列表非空）→ 放弃恢复。
        guard copilotList.isEmpty else {
            return .none
        }

        copilotSet = .init(kind: listing.kind, data: setData, url: url)
        let applied = CopilotPersistence.apply(state, to: listing.items)
        copilotList = applied
        // 降级恢复合并式存档：didSet 刚以幸存行整表落盘——把被跳过成员的旧
        // overrides/order 并回（apply 忽略未知 order 键；成员后续以就绪资源恢复
        // 时按用户此前勾选回归）。与赋值同一 MainActor 回合，无用户编辑竞态窗口。
        if !listing.skippedMemberIDs.isEmpty {
            CopilotPersistence.preserveSkippedOverrides(
                old: state, skippedMemberIDs: listing.skippedMemberIDs)
        }
        return .restored(active: applied.filter(\.isOn).count, skipped: listing.skipped)
    }
}

extension CopilotContext.Content {
    @concurrent init(url: URL) async {
        if url.isDirectory {
            if let set = CopilotSetData(atDirectory: url) {
                self = .set(url, set)
            } else {
                self = .directory
            }
        } else {
            if let copilot = MAACopilot(url: url) {
                let kind = await copilot.kind
                self = .copilot(url, kind, copilot)
            } else {
                self = .invalid
            }
        }
    }
}

extension CopilotSetData {
    /// 派生结果：集合类型 + 行清单 + 逐成员跳过原因（C09 损坏恢复——单个
    /// 成员缺失/损坏/映射失败只跳过该成员，不再让整个集合激活失败）。
    /// skippedMemberIDs 供降级恢复的合并式存档保留被跳过成员的归档行
    /// （评审 P13-1-R3 中危-2）。
    struct SetListing {
        let kind: MAACopilot.Kind
        let items: [CopilotContext.ListItem]
        let skipped: [String]
        let skippedMemberIDs: [String]
    }

    func copilotList(at url: URL) async -> SetListing? {
        guard url.isDirectory else { return nil }

        var copilotList = [CopilotContext.ListItem]()
        var skipped = [String]()
        var skippedMemberIDs = [String]()

        var lastCopilotKind: MAACopilot.Kind?

        for copilotID in copilot_ids {
            let memberURL = url.appending(path: "\(copilotID).json")
            guard let copilot = MAACopilot(url: memberURL) else {
                let reason = FileManager.default.fileExists(atPath: memberURL.path(percentEncoded: false))
                    ? String(localized: "文件损坏")
                    : String(localized: "文件缺失")
                skipped.append("\(copilotID).json（\(reason)）")
                skippedMemberIDs.append(String(copilotID))
                continue
            }
            guard let code = await MAAProvider.shared.mapLevelCode(matching: copilot.stage_name) else {
                skipped.append(
                    "\(copilotID).json（\(String(localized: "导航名映射失败"))）")
                skippedMemberIDs.append(String(copilotID))
                continue
            }

            let kind = copilot.kind(code: code)
            if lastCopilotKind == nil {
                lastCopilotKind = kind
            } else if lastCopilotKind != kind {
                print("Mixed copilot kind in list")
                return nil
            }

            switch copilot.difficulty {
            case nil, 0:
                copilotList.append(
                    .init(url: memberURL, stageCode: code, memberID: "\(copilotID)#0", isOn: true))
            case 1:
                copilotList.append(
                    .init(
                        url: memberURL, stageCode: code, memberID: "\(copilotID)#0",
                        isRaid: false, isOn: true))
            case 2:
                copilotList.append(
                    .init(
                        url: memberURL, stageCode: code, memberID: "\(copilotID)#1",
                        isRaid: true, isOn: true))
            case 3:
                copilotList.append(
                    .init(
                        url: memberURL, stageCode: code, memberID: "\(copilotID)#0",
                        isRaid: false, isOn: true))
                copilotList.append(
                    .init(
                        url: memberURL, stageCode: code, memberID: "\(copilotID)#1",
                        isRaid: true, isOn: true))
            default:
                // 难度值越界成员记因跳过（评审低-3：静默丢弃曾让全灭集合误报「清单损坏」）。
                skipped.append(
                    "\(copilotID).json（\(String(localized: "难度值不支持"))）")
                skippedMemberIDs.append(String(copilotID))
                continue
            }
        }

        // 空集合清单沿用旧的 regular 缺省；成员全灭（有 id 但无一可解析）视为
        // 集合不可用，与旧行为一致。
        if !copilot_ids.isEmpty && copilotList.isEmpty {
            return nil
        }
        return SetListing(
            kind: lastCopilotKind ?? .regular, items: copilotList, skipped: skipped,
            skippedMemberIDs: skippedMemberIDs)
    }
}

extension MAACopilot {
    enum Kind: Hashable {
        case regular
        case sss
        case paradox
    }

    func kind(code: String) -> Kind {
        if type == "SSS" {
            return .sss
        }
        if code.starts(with: "mem_") {
            return .paradox
        }
        return .regular
    }

    var kind: Kind {
        get async {
            if type == "SSS" {
                return .sss
            }
            let code = await MAAProvider.shared.mapLevelCode(matching: stage_name)
            if let code, code.starts(with: "mem_") {
                return .paradox
            }
            return .regular
        }
    }
}

extension MAACopilot.Kind {
    /// Fallback kind judgment for items that carry no activation-time level
    /// code: the runtime judgment resolves the code through MaaCore, which the
    /// compiler must not touch. Paradox level codes are `mem_`-prefixed and
    /// survive that mapping unchanged, so a prefix check on `stage_name`
    /// reaches the same verdict when `stage_name` itself is the code. List
    /// items built from an activated set always carry `stageCode` and take the
    /// mapped-code path instead (`CopilotCompiler.Input.Item.stageCode`).
    init(of copilot: MAACopilot) {
        if copilot.type == "SSS" {
            self = .sss
        } else if copilot.stage_name.hasPrefix("mem_") {
            self = .paradox
        } else {
            self = .regular
        }
    }

    /// The core task type this kind queues.
    var taskType: MAATaskType {
        switch self {
        case .regular:
            return .Copilot
        case .sss:
            return .SSSCopilot
        case .paradox:
            return .ParadoxCopilot
        }
    }

    /// Short user-facing name used in compile-rejection messages.
    var displayName: String {
        switch self {
        case .regular:
            return String(localized: "常规作业")
        case .sss:
            return String(localized: "保全作业")
        case .paradox:
            return String(localized: "悖论模拟作业")
        }
    }
}

// MARK: - PRTS 神秘代码（C02）

/// 作业站神秘代码：纯数字与 `prts://` 前缀为作业，`s`/`prts://s` 前缀为
/// 作业集；`maa://` 为仅作业的老格式（WPF 同构）。
enum PRTSCode: Hashable {
    case copilot(Int)
    case set(Int)
}

extension StringProtocol {
    var prtsCode: PRTSCode? {
        let string = trimmingCharacters(in: .whitespacesAndNewlines)

        if string.hasPrefix("maa://") {
            guard let digits = string.trimmingPrefix("maa://").digits, let id = Int(digits) else {
                return nil
            }
            return .copilot(id)
        }

        let trimmed = string.trimmingPrefix("prts://")
        if trimmed.starts(with: "s") {
            guard let digits = trimmed.trimmingPrefix("s").digits, let id = Int(digits) else {
                return nil
            }
            return .set(id)
        }
        guard let digits = trimmed.digits, let id = Int(digits) else {
            return nil
        }
        return .copilot(id)
    }

    private var digits: Self? {
        guard !isEmpty else {
            return nil
        }
        let predicate = allSatisfy { char in
            char.isASCII && char.isNumber
        }
        return predicate ? self : nil
    }
}
