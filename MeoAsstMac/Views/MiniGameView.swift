//
//  MiniGameView.swift
//  MAA
//
//  Created by ninekirin on 3/8/2025.
//

import SwiftUI

struct MiniGameView: View {
    @EnvironmentObject private var viewModel: MAAViewModel
    @SceneStorage("selectedMiniGame") private var selection = MiniGameOption.sideStoryStore.taskName
    @State private var selectedGame = MiniGameOption.sideStoryStore.tag
    @State private var taskParams: Any?
    @AppStorage("SecretFrontEnding") private var secretFrontEnding = SecretFrontConfiguration.Ending.A
    @AppStorage("SecretFrontEvent") private var secretFrontEvent = SecretFrontConfiguration.Event.unspecified
    @AppStorage("AutoRaisePotentialUseNormalToken") private var autoRaiseUseNormalToken = false
    @AppStorage("EventShopBlacklistData") private var eventShopBlacklistData = Data()
    // P17-[d]（快照 82 清单②裁定：随 WPF 对齐）：四类预设开关+Other 门控，
    // 键名随 WPF MiniGame.cs:32-42 配置名。缺省全 false（WPF 同）。
    @AppStorage("EventShopBlackListDataSupplementInstrument") private var eventShopBlackListDataSupplementInstrument = false
    @AppStorage("EventShopBlackListDataSupplementStick") private var eventShopBlackListDataSupplementStick = false
    @AppStorage("EventShopBlackListLmd") private var eventShopBlackListLmd = false
    @AppStorage("EventShopBlackListFurniturePart") private var eventShopBlackListFurniturePart = false
    @AppStorage("EventShopBlackListOther") private var eventShopBlackListOther = false
    @State private var startError: String?

    private var isSecretFront: Bool { selectedGame.taskName == MiniGameOption.secretFront.taskName }
    private var isAutoRaisePotential: Bool {
        selectedGame.taskName == MiniGameOption.autoRaisePotential.taskName
    }
    private var isSideStoryStore: Bool {
        selectedGame.taskName == MiniGameOption.sideStoryStore.taskName
    }

    /// T12 活动商店黑名单（UserDefaults JSON Data 持久化）。
    private var eventShopBlacklist: Binding<[String]> {
        Binding(
            get: { (try? JSONDecoder().decode([String].self, from: eventShopBlacklistData)) ?? [] },
            set: { eventShopBlacklistData = (try? JSONEncoder().encode($0)) ?? Data() })
    }


    var body: some View {
        VStack(spacing: 20) {
            TimelineView(.everyMinute) { context in
                Picker("选择小游戏", selection: $selectedGame) {
                    Section("当期活动") {
                        ForEach(otaMiniGames, id: \.Value) { game in
                            if game.isValid(at: context.date) {
                                // P17-[e]：版本门条目行尾 ⚠ 标记（Tip 正文见
                                // 选择器下方警示行——WPF entry.Tip 同语义）。
                                let entry = game.tag
                                Text(entry.versionTip == nil
                                     ? game.displayName : game.displayName + " ⚠️").tag(entry)
                            }
                        }
                    }
                    Section("常驻活动") {
                        ForEach(MiniGameOption.allCases, id: \.self) { game in
                            Text(game.displayName).tag(game.tag)
                        }
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: context.date) {
                    if !selectedGame.isValid(at: $1) {
                        selectedGame = MiniGameOption.greenTicketStore.tag
                    }
                }
            }

            // P17-[e]：选中 OTA 条目的版本门警示（WPF entry.Tip 语义——展示
            // 提示、不拦截启动）。
            if let versionTip = selectedGame.versionTip {
                Text(versionTip)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if isSecretFront {
                Picker("目标结局", selection: $secretFrontEnding) {
                    ForEach(SecretFrontConfiguration.Ending.allCases, id: \.self) { ending in
                        Text("结局 \(ending.rawValue)").tag(ending)
                    }
                }
                .disabled(viewModel.status != .idle)
                Picker("指定事件", selection: $secretFrontEvent) {
                    ForEach(SecretFrontConfiguration.Event.allCases, id: \.self) { event in
                        Text(event.displayName).tag(event)
                    }
                }
                .disabled(viewModel.status != .idle)
                if let reason = viewModel.secretFrontUnavailableReason {
                    Text(reason)
                        .foregroundStyle(.secondary)
                }
            }

            if isAutoRaisePotential {
                // T16：中控信物不足的确认弹窗默认放弃，开启后改消耗普通信物。
                Toggle("不足时消耗普通信物", isOn: $autoRaiseUseNormalToken)
                    .disabled(viewModel.status != .idle)
            }

            if isSideStoryStore {
                // P17-[d]：四类预设开关（WPF MiniGame.cs:32-42 配置名同源；
                // GUI 标签取 WPF zh-cn.xaml 五语键逐字）。预设关键词经
                // MiniGameLaunch.eventShopBlacklist 按**游戏客户端语言**映射
                // （非 GUI 语言，WPF StartEventShop :3639-3646 同语义）。
                Toggle("数据增补仪", isOn: $eventShopBlackListDataSupplementInstrument)
                    .disabled(viewModel.status != .idle)
                Toggle("数据增补条", isOn: $eventShopBlackListDataSupplementStick)
                    .disabled(viewModel.status != .idle)
                Toggle("龙门币", isOn: $eventShopBlackListLmd)
                    .disabled(viewModel.status != .idle)
                Toggle("家具零件", isOn: $eventShopBlackListFurniturePart)
                    .disabled(viewModel.status != .idle)
                Toggle("其他自定义商品", isOn: $eventShopBlackListOther)
                    .disabled(viewModel.status != .idle)
                // T12：活动商店商品黑名单（空名单=按默认流程购买；仅 Other
                // 开启时进入下发组合，WPF :3635-3638 同门控）。
                EditableTextList(title: "商品黑名单", texts: eventShopBlacklist)
            }

            Button("开始游戏") {
                startMiniGame()
            }
            .disabled(!viewModel.canStartTasks || (isSecretFront && viewModel.secretFrontUnavailableReason != nil))
            .buttonStyle(.borderedProminent)

            Divider()

            switch selectedGame.taskName {
            case "MiniGame@PixelPaint@Begin":
                PixelPaintView(params: $taskParams)
            case MiniGameOption.secretFront.taskName:
                VStack(alignment: .leading, spacing: 12) {
                    Text(selectedGame.instructions)
                    Text("运行日志").font(.headline)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(viewModel.secretFrontRun.messages.enumerated()), id: \.offset) { _, message in
                                Text(message).textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            default:
                ScrollView {
                    LazyVStack {
                        Text(selectedGame.instructions)
                    }
                }
            }
        }
        .padding()
        .alert("小游戏启动失败", isPresented: Binding(
            get: { startError != nil }, set: { if !$0 { startError = nil } }
        )) {
            Button("好", role: .cancel) { startError = nil }
        } message: { Text(startError ?? "") }
        .animation(.default, value: otaMiniGames)
        .animation(.default, value: selectedGame)
        .onChange(of: otaMiniGames, initial: true) {
            for game in $1 {
                if game.Value == selection {
                    selectedGame = game.tag
                    return
                }
            }
            for game in MiniGameOption.allCases {
                if game.taskName == selection {
                    selectedGame = game.tag
                    return
                }
            }
        }
        .onChange(of: selectedGame) {
            selection = $1.taskName
            taskParams = nil
        }
    }

    private var otaMiniGames: [MAAStageActivity.MiniGame] {
        viewModel.stageActivity?.miniGame ?? []
    }

    private func startMiniGame() {
        Task {
            do {
                if isSecretFront {
                    guard viewModel.secretFrontUnavailableReason == nil else { return }
                    let configuration = SecretFrontConfiguration(ending: secretFrontEnding, event: secretFrontEvent)
                    try await viewModel.miniGame(name: configuration.taskName, secretFront: configuration)
                } else if isAutoRaisePotential {
                    // T16：params.auto_raise_potential.use_normal_token（Core 双层嵌套契约）。
                    try await viewModel.miniGame(
                        name: selectedGame.taskName,
                        params: MiniGameLaunch.autoRaisePotential(useNormalToken: autoRaiseUseNormalToken))
                } else if isSideStoryStore {
                    // T12/P17-[d]：params.event_shop.blacklist——Other 门控自定义
                    // （Distinct 保序）+四类预设按客户端语言映射追加（WPF
                    // StartEventShop :3635-3656 同构）；空名单不传（Core 走默认流程）。
                    try await viewModel.miniGame(
                        name: selectedGame.taskName,
                        params: MiniGameLaunch.eventShop(blacklist: MiniGameLaunch.eventShopBlacklist(
                            custom: eventShopBlacklist.wrappedValue,
                            otherEnabled: eventShopBlackListOther,
                            instrument: eventShopBlackListDataSupplementInstrument,
                            stick: eventShopBlackListDataSupplementStick,
                            lmd: eventShopBlackListLmd,
                            furniturePart: eventShopBlackListFurniturePart,
                            channelRawValue: viewModel.clientChannel.rawValue)))
                } else if selectedGame.taskName == MiniGameOption.pixelPaint.taskName {
                    // P17-[c]（快照 82 清单②裁定：随 WPF 对齐，2026-11-09）：
                    // 空图/零分组拒启+警示（WPF ToolboxViewModel
                    // .CheckSelectedMiniGameReady :3590-3597 NeedImage），不再
                    // 静默下发空 params 空跑。
                    let pixelParams = taskParams as? [String: Any]
                    let groups = (pixelParams?["pixel_paint"] as? [String: Any])?["groups"] as? [Any]
                    guard let groups, !groups.isEmpty else {
                        startError = String(localized: "请先导入图片并生成预览")
                        return
                    }
                    try await viewModel.miniGame(name: selectedGame.taskName, params: taskParams)
                } else {
                    try await viewModel.miniGame(name: selectedGame.taskName, params: taskParams)
                }
            } catch MAAError.taskOperationInProgress, MAAError.taskAlreadyRunning {
                // beginTaskOperation already reported these through the log channel.
            } catch {
                startError = error.localizedDescription
            }
        }
    }
}

enum MiniGameOption: String, CaseIterable {
    case sideStoryStore
    case greenTicketStore
    case yellowTickerStore
    case reclamationStore
    case secretFront
    case autoRaisePotential
    case materialSynthesis
    case pixelPaint

    var taskName: String {
        switch self {
        case .secretFront:
            return "MiniGame@SecretFront@Begin"
        case .greenTicketStore:
            return "GreenTicket@Store@Begin"
        case .yellowTickerStore:
            return "YellowTicket@Store@Begin"
        case .sideStoryStore:
            return "SS@Store@Begin"
        case .reclamationStore:
            return "RA@Store@Begin"
        case .autoRaisePotential:
            return "MiniGame@AutoRaisePotential@Begin"
        case .materialSynthesis:
            return "MiniGame@MaterialSynthesis@Begin"
        case .pixelPaint:
            return "MiniGame@PixelPaint@Begin"
        }
    }

    var displayName: String {
        switch self {
        case .secretFront:
            return String(localized: "隐秘战线")
        case .greenTicketStore:
            return String(localized: "绿票商店")
        case .yellowTickerStore:
            return String(localized: "黄票商店")
        case .sideStoryStore:
            return String(localized: "活动商店")
        case .reclamationStore:
            return String(localized: "生息演算商店")
        case .autoRaisePotential:
            return String(localized: "自动提升潜能")
        case .materialSynthesis:
            return String(localized: "缺口材料合成")
        case .pixelPaint:
            return String(localized: "像素画")
        }
    }

    var instructions: String {
        switch self {
        case .secretFront:
            String(localized: "请先进入隐秘战线的分队选择页面。指定事件出现时优先选择，成功率不足时可能先积累属性。识别失败时可用工具栏停止；从路线、危机或终点页面恢复需要相应 Core 资源支持。")
        case .greenTicketStore:
            String(
                localized:
                    """
                    1层全买。
                    2层买寻访凭证和招聘许可。
                    """)
        case .yellowTickerStore:
            String(
                localized:
                    """
                    购买寻访凭证。
                    请确保自己至少有258张黄票。
                    """)
        case .sideStoryStore:
            String(
                localized:
                    """
                    请在活动商店页面开始。
                    不买无限池。
                    """)
        case .reclamationStore:
            String(
                localized:
                    """
                    请在活动商店页面开始。
                    """)
        case .autoRaisePotential:
            String(localized: "请进入干员潜能提升界面。中控信物不足时默认放弃提升，可开启「不足时消耗普通信物」改用普通信物。")
        case .materialSynthesis:
            String(localized: "请在合成站页面开始。任务会按缺口自动合成所需材料。")
        case .pixelPaint:
            String(localized: "导入图片并预览后开始绘制，绘制过程中可随时停止。")
        }
    }
}

@available(*, unavailable, message: "This type is only for localization key extraction.")
private enum LocalizableMiniGameKey {
}

struct MiniGameView_Previews: PreviewProvider {
    static var previews: some View {
        MiniGameView()
            .environmentObject(MAAViewModel())
    }
}

private struct MiniGameTag: Hashable {
    let instructions: String
    let taskName: String
    let activation: Date?
    let expiry: Date?
    /// P17-[e]：OTA 条目版本门 Tip（nil=无需警示；常驻入口恒 nil）。
    var versionTip: String? = nil

    func isValid(at date: Date = .now) -> Bool {
        guard let activation, let expiry else {
            return true
        }
        return date >= activation && date <= expiry
    }
}

extension MiniGameOption {
    fileprivate var tag: MiniGameTag {
        .init(
            instructions: instructions, taskName: taskName,
            activation: nil, expiry: nil)
    }
}

extension MAAStageActivity.MiniGame {
    var displayName: String {
        let defaultDisplay = Display ?? Value
        if let DisplayKey {
            return Bundle.main.localizedString(forKey: DisplayKey, value: defaultDisplay, table: nil)
        } else {
            return defaultDisplay
        }
    }

    fileprivate var tag: MiniGameTag {
        let defaultTip = Tip ?? ""
        let tip: String
        if let TipKey {
            tip = Bundle.main.localizedString(forKey: TipKey, value: defaultTip, table: nil)
        } else {
            tip = defaultTip
        }
        // P17-[e]：MinimumRequired 版本门（WPF StageManager.cs:560-582——Tip 非
        // 硬门禁；WPF isDebugVersion 豁免在 Mac 无 debug 渠道概念——Mac 侧门
        // 恒启用、无豁免面，S8-1-R3 低-3 措辞勘正）。
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? ""
        return .init(
            instructions: tip, taskName: Value,
            activation: startTime, expiry: expireTime,
            versionTip: StageActivityVersionGate.lowVersionTip(
                minimumRequired: MinimumRequired, currentVersion: currentVersion))
    }

    func isValid(at date: Date = .now) -> Bool {
        date >= startTime && date <= expireTime
    }
}
