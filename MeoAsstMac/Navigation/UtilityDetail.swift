//
//  UtilityDetail.swift
//  MAA
//
//  Created by hguandl on 19/4/2023.
//

import SwiftUI

struct UtilityDetail: View {
    @EnvironmentObject private var viewModel: MAAViewModel
    let entry: UtilityEntry?
    @State private var showInfo = true

    @ViewBuilder var content: some View {
        if showInfo {
            switch entry {
            case .recruit:
                RecruitView()
            case .depot:
                DepotView()
            case .oper:
                OperBoxView()
            case .video:
                VideoRecogView()
            case .gacha:
                GachaView()
            case .minigame:
                MiniGameView()
            case .peep:
                PeepView()
            case .maatools:
                MaaToolsView()
            case .achievements:
                AchievementView()
            case .none:
                Text("请选择工具项目")
            }
        } else {
            LogView()
        }
    }

    var body: some View {
        VStack {
            if entry == .depot || entry == .oper { UserDataHistorySummary(showsOperators: entry == .oper) }
            content
        }
        .padding()
        .toolbar {
            UtilityTitle(description: entry?.description)
            ToolbarItem {
                Picker("工具介绍", selection: $showInfo) {
                    Label("info", systemImage: "info")
                        .tag(true)
                        .help("工具介绍")
                    Label("日志", systemImage: "note.text")
                        .tag(false)
                        .help("运行日志")
                }
                .pickerStyle(.segmented)
            }
        }
    }
}

struct UtilityDetail_Previews: PreviewProvider {
    static var previews: some View {
        UtilityDetail(entry: .recruit)
            .environmentObject(MAAViewModel())
    }
}

private struct UtilityTitle: ToolbarContent {
    let description: String?

    var body: some ToolbarContent {
        let item = ToolbarItem {
            Text(description ?? String(localized: "实用工具"))
                .padding(.leading, 5)
                .font(.headline)
        }
        if #available(macOS 26.0, *) {
            item.sharedBackgroundVisibility(.hidden)
        } else {
            item
        }
    }
}


private struct UserDataHistorySummary: View {
    let showsOperators: Bool
    @EnvironmentObject private var viewModel: MAAViewModel
    @State private var history: DepotHistoryStore.Snapshot?
    @State private var operatorHistory: OperBoxHistoryStore.Snapshot?
    @State private var loadFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("资料账号标识（本地自定义）", text: $viewModel.userDataAccount)
                .disabled(!viewModel.canStartTasks)
            Text("请按游戏账号分别命名；此标识不验证登录身份。游戏切换账号后将清空绑定。历史快照仅供查看，重启后仍须重新识别库存。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("刷新仓库与干员资料") {
                Task {
                    do { try await viewModel.refreshUserData() }
                    catch { viewModel.logError(verbatim: error.localizedDescription) }
                }
            }.disabled(!viewModel.canStartTasks)
            if !showsOperators, let history {
                HStack {
                    Text("历史仓库快照")
                    Text(history.capturedAt, style: .date)
                    Text(history.capturedAt, style: .time)
                    Text(verbatim: history.scope.server)
                }.font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("查看历史仓库快照") {
                    ScrollView {
                        LazyVStack(alignment: .leading) {
                            ForEach(history.items.keys.sorted(), id: \.self) { item in
                                Text(verbatim: "\(item)：\(history.items[item] ?? 0)")
                            }
                        }
                    }.frame(maxHeight: 160)
                }
            }
            if showsOperators, let operatorHistory {
                HStack {
                    Text("历史干员快照")
                    Text(operatorHistory.capturedAt, style: .date)
                    Text(operatorHistory.capturedAt, style: .time)
                    Text(verbatim: operatorHistory.scope.server)
                }.font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("查看历史干员快照") {
                    ScrollView {
                        LazyVStack(alignment: .leading) {
                            ForEach(operatorHistory.operators.ownedOperators.sorted { $0.id < $1.id }) { oper in
                                Text(verbatim: "\(oper.name) · E\(oper.elite) Lv\(oper.level) · P\(oper.potential)")
                            }
                        }
                    }.frame(maxHeight: 160)
                }
                Text("干员识别结果不包含技能、专精与模组信息，历史快照不会补造这些字段。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if loadFailed { Text("历史资料读取失败；请重新识别。").foregroundStyle(.red) }
        }
        .task(id: viewModel.inventoryScope) { reload() }
        .onChange(of: showsOperators) { _, _ in reload() }
        .onChange(of: viewModel.inventory.snapshot?.generation) { _, _ in reload() }
        .onChange(of: viewModel.operBoxHistoryRevision) { _, _ in reload() }
    }

    private func reload() {
        history = nil; operatorHistory = nil; loadFailed = false
        do {
            if showsOperators {
                operatorHistory = try viewModel.operBoxHistoryStore.load(scope: viewModel.inventoryScope)
            } else {
                history = try viewModel.depotHistoryStore.load(scope: viewModel.inventoryScope)
            }
        } catch { loadFailed = true }
    }
}
