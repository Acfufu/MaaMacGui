//
//  UtilityDetail.swift
//  MAA
//
//  Created by hguandl on 19/4/2023.
//

import SwiftUI
import UniformTypeIdentifiers

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
    @Environment(\.locale) private var locale
    @State private var history: DepotHistoryStore.Snapshot?
    @State private var operatorHistory: OperBoxHistoryStore.Snapshot?
    @State private var operatorExportMessage: String?
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
                // T09 干员导出（WPF ExportOperBoxToJson/Markdown/Csv 基础列同构；
                // 一图流技能/模组列需快照不承载数据，保持开放）。
                Menu("导出干员资料") {
                    Button("JSON") { exportOperators(.json) }
                    Button("Markdown") { exportOperators(.markdown) }
                    Button("CSV") { exportOperators(.csv) }
                }
                .disabled(operatorHistory == nil)
                if let operatorExportMessage {
                    Text(operatorExportMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            if showsOperators {
                // I04 只读练度导入：不发 Core 任务；与识别按钮互不影响（WPF 用设置项切换
                // 同一入口，Mac 保留识别路径不变、独立导入按钮，差异入档）。
                SecureField("一图流 OpenAPI Token", text: $viewModel.yituliuOpenApiToken)
                HStack {
                    Button("从一图流导入干员练度") {
                        Task { await viewModel.importOperBoxFromYituliu(localeIdentifier: locale.identifier) }
                    }
                    .disabled(viewModel.yituliuImportInFlight)
                    if viewModel.yituliuImportInFlight {
                        ProgressView().controlSize(.small)
                    }
                }
                Text("Token 只保存在本机偏好设置且不进入日志；导入数据按当前账号/区服隔离，未绑定或为空时保留本地快照。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("日常更新资料的干员识别改用一图流", isOn: $viewModel.yituliuOperBoxForDaily)
                Text("开启后每日更新资料不再为干员部分启动模拟器识别；Token 为空时该次运行失败，其余失败按条目记录，不影响仓库识别。")
                    .font(.caption).foregroundStyle(.secondary)
                if let message = viewModel.yituliuImportMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
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

    private enum OperatorExportFormat { case json, markdown, csv }

    /// WPF ExportOperBoxToFile 同构：按持有列表导出；JSON 缩进、md/csv 基础 7 列、
    /// UTF-8 BOM（Excel 兼容）；空集按钮已禁用，构建层空集兜底不产生文件。
    private func exportOperators(_ format: OperatorExportFormat) {
        guard let snapshot = operatorHistory else { return }
        // 与 MAAOperBox.OwnedOper 的展示排序同构（快照负载类型未声明 Comparable）。
        let owned = snapshot.operators.ownedOperators.sorted { lhs, rhs in
            if lhs.elite != rhs.elite { return lhs.elite > rhs.elite }
            if lhs.level != rhs.level { return lhs.level > rhs.level }
            if lhs.rarity != rhs.rarity { return lhs.rarity > rhs.rarity }
            return lhs.id < rhs.id
        }
        let headers = DataExport.OperBoxHeaders(
            name: String(localized: "名称"), id: String(localized: "ID"),
            rarity: String(localized: "星级"), elite: String(localized: "精英化"),
            level: String(localized: "等级"), own: String(localized: "已持有"),
            potential: String(localized: "潜能"), yes: String(localized: "是"), no: String(localized: "否"))
        let panel = NSSavePanel()
        let content: String
        switch format {
        case .json:
            guard let data = try? JSONEncoder().encode(owned) else { return }
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "Arknights_OperBox_Export.json"
            content = String(decoding: data, as: UTF8.self)
        case .markdown:
            let rows = owned.map {
                DataExport.OperBoxRow(name: $0.name, id: $0.id, rarity: $0.rarity,
                                      elite: $0.elite, level: $0.level, own: $0.own, potential: $0.potential)
            }
            guard let joined = DataExport.joinedLines(DataExport.operBoxMarkdownLines(rows: rows, headers: headers)) else { return }
            panel.allowedContentTypes = [.plainText]
            panel.nameFieldStringValue = "Arknights_OperBox_Export.md"
            content = joined
        case .csv:
            let rows = owned.map {
                DataExport.OperBoxRow(name: $0.name, id: $0.id, rarity: $0.rarity,
                                      elite: $0.elite, level: $0.level, own: $0.own, potential: $0.potential)
            }
            guard let joined = DataExport.joinedLines(DataExport.operBoxCsvLines(rows: rows, headers: headers)) else { return }
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.nameFieldStringValue = "Arknights_OperBox_Export.csv"
            content = joined
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try DataExport.write(content, to: url, withBOM: format != .json)
            operatorExportMessage = String(localized: "已导出：\(url.path)")
        } catch {
            operatorExportMessage = String(localized: "导出失败：\(error.localizedDescription)")
        }
    }
}
